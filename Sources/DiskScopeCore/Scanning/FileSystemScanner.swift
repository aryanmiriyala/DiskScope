import Foundation

/// Knobs for a scan. Everything the scanner does is driven from here so that a
/// run is reproducible and testable.
public struct ScanConfiguration: Sendable {
    /// Explicit roots. The scanner never walks anything not derived from these.
    public var roots: [URL]

    /// Files at or above this size get recorded individually.
    public var largeFileThreshold: Int64

    /// Upper bound on remembered large files, to keep memory flat on
    /// pathological machines with a million 100 MB files.
    public var maximumLargeFiles: Int

    /// Maximum directory depth below each root. Guards against runaway trees.
    public var maximumDepth: Int

    /// Maximum concurrent directory walks.
    public var concurrency: Int

    /// Do not descend into directories on a different device than their parent.
    /// This keeps a home-directory scan from wandering into mounted network
    /// shares or external volumes, which are frequently enormous and slow.
    public var stayOnOneFilesystem: Bool

    /// Paths (and their contents) to skip entirely, by exact path match.
    public var excludedPaths: Set<String>

    /// Skip the .git internal history of git repositories. Large `.git`
    /// directories are real space, but unpacking them is not useful detail.
    public var skipGitInternals: Bool

    public init(
        roots: [URL],
        largeFileThreshold: Int64 = 100 * 1024 * 1024,
        maximumLargeFiles: Int = 2_000,
        maximumDepth: Int = 64,
        concurrency: Int = 8,
        stayOnOneFilesystem: Bool = true,
        excludedPaths: Set<String> = [],
        skipGitInternals: Bool = true
    ) {
        self.roots = roots
        self.largeFileThreshold = largeFileThreshold
        self.maximumLargeFiles = maximumLargeFiles
        self.maximumDepth = maximumDepth
        self.concurrency = max(1, concurrency)
        self.stayOnOneFilesystem = stayOnOneFilesystem
        self.excludedPaths = excludedPaths
        self.skipGitInternals = skipGitInternals
    }

    public static var homeLibrary: ScanConfiguration {
        ScanConfiguration(roots: [URL.homeDirectory.appending(path: "Library")])
    }

    public static var home: ScanConfiguration {
        ScanConfiguration(roots: [URL.homeDirectory])
    }
}

/// Progress emitted while scanning, for the UI.
public struct ScanProgress: Sendable {
    public var directoriesVisited: Int
    public var filesSeen: Int
    public var bytesSeen: Int64
    public var currentPath: String
    public var deniedCount: Int

    public init(
        directoriesVisited: Int = 0,
        filesSeen: Int = 0,
        bytesSeen: Int64 = 0,
        currentPath: String = "",
        deniedCount: Int = 0
    ) {
        self.directoriesVisited = directoriesVisited
        self.filesSeen = filesSeen
        self.bytesSeen = bytesSeen
        self.currentPath = currentPath
        self.deniedCount = deniedCount
    }
}

/// Thread-safe accumulator for the values the scan shares across its
/// concurrent directory walks.
final class ScanAccumulator: @unchecked Sendable {
    private let lock = NSLock()

    private var records: [DirectoryRecord] = []
    private var largeFiles: [LargeFileRecord] = []
    private var denied: [DeniedPathRecord] = []
    /// (device, inode) pairs already counted, so N hard links to one 4 GB file
    /// are reported as 4 GB rather than 12 GB.
    private var countedInodes: Set<HardlinkKey> = []
    private var deduplicatedHardLinks = 0

    private var directoriesVisited = 0
    private var filesSeen = 0
    private var bytesSeen: Int64 = 0
    private var currentPath = ""

    struct HardlinkKey: Hashable {
        let device: UInt64
        let inode: UInt64
    }

    /// Returns true if this inode has not been counted before.
    ///
    /// Only files with `nlink > 1` are consulted, so ordinary files skip the
    /// hash-set cost entirely.
    func shouldCount(device: UInt64, inode: UInt64, linkCount: UInt16) -> Bool {
        guard linkCount > 1 else { return true }
        lock.lock()
        defer { lock.unlock() }
        let key = HardlinkKey(device: device, inode: inode)
        if countedInodes.contains(key) {
            deduplicatedHardLinks += 1
            return false
        }
        countedInodes.insert(key)
        return true
    }

    func addDirectory(_ record: DirectoryRecord) {
        lock.lock()
        records.append(record)
        directoriesVisited += 1
        currentPath = record.url.path
        lock.unlock()
    }

    func addLargeFile(_ record: LargeFileRecord) {
        lock.lock()
        largeFiles.append(record)
        lock.unlock()
    }

    func addDenial(_ url: URL, reason: DeniedPathRecord.Reason) {
        lock.lock()
        denied.append(DeniedPathRecord(url: url, reason: reason))
        lock.unlock()
    }

    func noteFile(_ size: Int64) {
        lock.lock()
        filesSeen += 1
        bytesSeen &+= size
        lock.unlock()
    }

    func noteDenial() {
        lock.lock()
        denied.append(DeniedPathRecord(url: URL(fileURLWithPath: ""), reason: .permissionDenied))
        lock.unlock()
    }

    var deduplicatedHardLinkCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return deduplicatedHardLinks
    }

    func snapshot() -> (directories: Int, files: Int, bytes: Int64, path: String, denied: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (directoriesVisited, filesSeen, bytesSeen, currentPath, denied.count)
    }

    func drain(
        maximumLargeFiles: Int
    ) -> (records: [DirectoryRecord], largeFiles: [LargeFileRecord], denied: [DeniedPathRecord]) {
        lock.lock()
        defer { lock.unlock() }

        // Keep the biggest offenders; the tail is noise even if it exists.
        let trimmedLarge = largeFiles
            .sorted { $0.logicalSize > $1.logicalSize }
            .prefix(maximumLargeFiles)

        let result = (records, Array(trimmedLarge), denied)
        records = []
        largeFiles = []
        denied = []
        return result
    }
}

/// Walks a filesystem tree and aggregates space usage.
///
/// Design notes worth keeping:
///
/// * **Physical size, not just logical.** `st_blocks * 512` is what the file
///   actually costs on the volume. A 40 KB file occupies 8 KB of blocks on APFS,
///   so a directory of tens of thousands of tiny files can be far larger on disk
///   than the sum of its file sizes. Reporting only logical size is why some
///   "empty looking" directories turn out to be hundreds of megabytes.
///
/// * **Hard links counted once.** Xcode and Photos both create hard links.
///   Counting them per-path inflates totals badly.
///
/// * **Symlinks are never followed.** Following them can escape the requested
///   roots or loop forever. They are recorded as entries and not traversed.
///
/// * **Never silently ignore what we could not read.** Every `EACCES` becomes a
///   `DeniedPathRecord`.
public struct FileSystemScanner: Sendable {
    public let configuration: ScanConfiguration

    private let accumulator: ScanAccumulator
    private let semaphore: AsyncSemaphore

    public init(configuration: ScanConfiguration) {
        self.configuration = configuration
        self.accumulator = ScanAccumulator()
        // Directory metadata operations are cheap; file reads are not, and those
        // happen in the duplicate finder under its own budget.
        self.semaphore = AsyncSemaphore(permits: configuration.concurrency)
    }

    /// Result of walking one directory and everything under it.
    private struct Aggregate: Sendable {
        var logicalSize: Int64 = 0
        var allocatedSize: Int64 = 0
        var fileCount: Int = 0
        var directoryCount: Int = 1
        var symlinkCount: Int = 0
        var newestModification: Date?

        mutating func absorb(_ other: Aggregate) {
            logicalSize &+= other.logicalSize
            allocatedSize &+= other.allocatedSize
            fileCount += other.fileCount
            directoryCount += other.directoryCount
            symlinkCount += other.symlinkCount
            if let date = other.newestModification,
               newestModification == nil || date > newestModification! {
                newestModification = date
            }
        }
    }

    /// Scan every configured root.
    ///
    /// Returns a stream of progress alongside the final result so callers can
    /// render a live view without a second, redundant walk.
    public func scan() -> AsyncThrowingStream<ScanUpdate, Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                if Task.isCancelled {
                    continuation.finish(throwing: CancellationError())
                    return
                }

                var result = ScanResult(roots: configuration.roots, startedAt: .now)

                for root in configuration.roots {
                    let aggregate = await scanDirectory(at: root, rootDevice: nil, depth: 0)
                    result.scannedLogicalSize &+= aggregate.logicalSize
                    result.scannedAllocatedSize &+= aggregate.allocatedSize
                }

                let drained = accumulator.drain(maximumLargeFiles: configuration.maximumLargeFiles)
                result.directories = drained.records
                result.largeFiles = drained.largeFiles
                result.deniedPaths = drained.denied
                result.deduplicatedHardLinks = accumulator.deduplicatedHardLinkCount
                result.volumeTotals = VolumeProbe.usage()
                result.finishedAt = .now

                continuation.yield(.finished(result))
                continuation.finish()
            }

            // A separate lightweight task pumps progress so the walk itself is
            // never throttled by how fast the UI can draw.
            let progressTask = Task.detached(priority: .utility) {
                while !Task.isCancelled {
                    let snap = accumulator.snapshot()
                    continuation.yield(.progress(ScanProgress(
                        directoriesVisited: snap.directories,
                        filesSeen: snap.files,
                        bytesSeen: snap.bytes,
                        currentPath: snap.path,
                        deniedCount: snap.denied
                    )))
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
                progressTask.cancel()
            }
        }
    }

    /// Scan and return only the result, for tests and batch use.
    public func scanToCompletion() async throws -> ScanResult {
        var final: ScanResult?
        for try await update in scan() {
            if case .finished(let result) = update { final = result }
        }
        guard let final else {
            throw ScanError.noRootsScanned
        }
        return final
    }

    // MARK: - Directory walking

    /// Walk one directory and everything beneath it.
    ///
    /// Non-throwing by design: an unreadable directory is a normal outcome that
    /// becomes a `DeniedPathRecord`, not an error that aborts the run. The user
    /// gets a complete report of what was readable plus an explicit list of what
    /// was not, which is strictly more useful than a partial scan.
    private func scanDirectory(at url: URL, rootDevice: UInt64?, depth: Int) async -> Aggregate {
        guard depth <= configuration.maximumDepth else {
            accumulator.addDenial(url, reason: .tooManyLevelsOfSymbolicLinks)
            return Aggregate()
        }

        if configuration.excludedPaths.contains(url.path) {
            return Aggregate()
        }

        let name = url.lastPathComponent
        if configuration.skipGitInternals, name == ".git" {
            return Aggregate()
        }

        // Enumerate this directory's entries under a permit, then release the
        // permit *before* recursing. Holding it across the recursive descent is
        // what deadlocks: an ancestor sitting on a permit while awaiting a child
        // that cannot acquire one.
        //
        // Returns everything discovered here, and releases the permit before
        // returning, so callers are free to recurse.
        let enumeration = await semaphore.withPermit { [self] in
            enumerate(url: url)
        }

        var aggregate = Aggregate()
        aggregate.symlinkCount = enumeration.symlinkCount

        // Account for files in this directory.
        var ownLogical: Int64 = 0
        var ownAllocated: Int64 = 0
        let threshold = configuration.largeFileThreshold

        for file in enumeration.files {
            let logical = Int64(file.st.st_size)
            let allocated = Int64(file.st.st_blocks) * 512

            let countIt = accumulator.shouldCount(
                device: UInt64(file.st.st_dev),
                inode: UInt64(file.st.st_ino),
                linkCount: file.st.st_nlink
            )

            if countIt {
                ownLogical &+= logical
                ownAllocated &+= allocated
                aggregate.fileCount += 1
                accumulator.noteFile(logical)
            }

            let modified = modificationDate(file.st.st_mtimespec)
            if let modified, aggregate.newestModification == nil || modified > aggregate.newestModification! {
                aggregate.newestModification = modified
            }

            if logical >= threshold {
                accumulator.addLargeFile(LargeFileRecord(
                    url: url.appending(path: file.name),
                    logicalSize: logical,
                    allocatedSize: allocated,
                    modificationDate: modified,
                    isHardLinked: file.st.st_nlink > 1
                ))
            }
        }

        let childDirectories = enumeration.children
        let effectiveDevice = enumeration.device

        // Walk subdirectories. Small fan-outs recurse inline because spinning up
        // a task group costs more than the parallelism saves, and a tree is
        // mostly directories with a handful of children.
        if childDirectories.count > 1 {
            await withTaskGroup(of: Aggregate.self) { group in
                for child in childDirectories.prefix(configuration.concurrency * 4) {
                    group.addTask { [self] in
                        await scanDirectory(at: child, rootDevice: effectiveDevice, depth: depth + 1)
                    }
                }
                for await childAggregate in group {
                    aggregate.absorb(childAggregate)
                }
            }

            // Anything past the fan-out cap gets walked sequentially. Rare, but
            // silently dropping it would under-report, which we refuse to do.
            if childDirectories.count > configuration.concurrency * 4 {
                for child in childDirectories.dropFirst(configuration.concurrency * 4) {
                    aggregate.absorb(await scanDirectory(at: child, rootDevice: effectiveDevice, depth: depth + 1))
                }
            }
        } else if let only = childDirectories.first {
            aggregate.absorb(await scanDirectory(at: only, rootDevice: effectiveDevice, depth: depth + 1))
        }

        let record = DirectoryRecord(
            url: url,
            name: url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent,
            kind: .directory,
            ownLogicalSize: ownLogical,
            ownAllocatedSize: ownAllocated,
            subtreeLogicalSize: aggregate.logicalSize + ownLogical,
            subtreeAllocatedSize: aggregate.allocatedSize + ownAllocated,
            fileCount: aggregate.fileCount,
            directoryCount: aggregate.directoryCount,
            symlinkCount: aggregate.symlinkCount,
            newestModification: aggregate.newestModification
        )
        accumulator.addDirectory(record)

        aggregate.logicalSize &+= ownLogical
        aggregate.allocatedSize &+= ownAllocated
        return aggregate
    }

    /// What a single directory's enumeration found.
    private struct Enumeration: Sendable {
        var children: [URL] = []
        var files: [(name: String, st: stat)] = []
        var symlinkCount: Int = 0
        var device: UInt64?
        /// Files that are neither directories, regular files nor symlinks.
        var otherCount: Int = 0
    }

    /// Read one directory's entries. Runs while holding a semaphore permit.
    ///
    /// Split out from `scanDirectory` so the permit's scope is unambiguous: it
    /// covers exactly this, and is released before any recursion happens.
    private func enumerate(url: URL) -> Enumeration {
        var result = Enumeration()

        let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            accumulator.addDenial(url, reason: reasonFor(errno))
            return result
        }

        guard let dirStream = fdopendir(fd) else {
            close(fd)
            accumulator.addDenial(url, reason: .unreadable)
            return result
        }
        defer { closedir(dirStream) }

        var dirStat = stat()
        result.device = fstat(fd, &dirStat) == 0 ? UInt64(dirStat.st_dev) : nil

        while let entry = readdir(dirStream) {
            let entryName = withUnsafeBytes(of: entry.pointee.d_name) { raw -> String in
                let bytes = raw.bindMemory(to: UInt8.self)
                // `d_name` is a fixed-size, NUL-padded C array.
                let nulIndex = bytes.firstIndex(of: 0) ?? bytes.count
                return String(decoding: bytes[0..<nulIndex], as: UTF8.self)
            }

            if entryName == "." || entryName == ".." { continue }

            var childStat = stat()
            let status = entryName.withCString { fstatat(fd, $0, &childStat, AT_SYMLINK_NOFOLLOW) }
            guard status == 0 else {
                accumulator.addDenial(url.appending(path: entryName), reason: reasonFor(errno))
                continue
            }

            switch childStat.st_mode & S_IFMT {
            case S_IFDIR:
                result.children.append(url.appending(path: entryName))
            case S_IFREG:
                result.files.append((entryName, childStat))
            case S_IFLNK:
                // A symlink is metadata: `st_size` is the length of the target
                // path, not real content, and the target itself is either
                // counted where it lives or deliberately not followed. Counting
                // it as a file would inflate both the file count and the byte
                // total with numbers that mean nothing.
                result.symlinkCount += 1
            default:
                // Sockets, FIFOs, devices. They occupy space but are not files
                // the user can do anything about.
                result.otherCount += 1
            }
        }

        return result
    }

    private func modificationDate(_ spec: timespec) -> Date? {
        guard spec.tv_sec != 0 || spec.tv_nsec != 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(spec.tv_sec) + TimeInterval(spec.tv_nsec) / 1_000_000_000)
    }

    private func reasonFor(_ code: Int32) -> DeniedPathRecord.Reason {
        switch code {
        case EACCES, EPERM: return .permissionDenied
        case ENOENT: return .notFound
        case ELOOP: return .tooManyLevelsOfSymbolicLinks
        case ETIMEDOUT: return .timedOut
        default: return .unreadable
        }
    }
}

/// What a scan stream yields.
public enum ScanUpdate: Sendable {
    case progress(ScanProgress)
    case finished(ScanResult)
}

public enum ScanError: LocalizedError, Sendable {
    case noRootsScanned
    case unreadableRoot(URL)

    public var errorDescription: String? {
        switch self {
        case .noRootsScanned:
            return "The scan finished without visiting any directories."
        case .unreadableRoot(let url):
            return "Could not open \(url.path). macOS may be blocking access to it."
        }
    }
}
