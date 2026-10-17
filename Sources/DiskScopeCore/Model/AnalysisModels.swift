import Foundation

/// A set of byte-identical files, with the space wasted by keeping all copies.
///
/// The `primaryCopy` is chosen as the oldest file, on the theory that the oldest
/// one is the original and the others are accidental copies. That is a heuristic,
/// not a guarantee, which is why this category defaults to `.destructive` and the
/// UI makes you pick what survives.
public struct DuplicateGroup: Sendable, Identifiable, Codable {
    public struct Member: Sendable, Identifiable, Codable, Hashable {
        public let url: URL
        public let logicalSize: Int64
        public let modificationDate: Date?
        public let isHardLinked: Bool

        public var id: URL { url }

        public init(url: URL, logicalSize: Int64, modificationDate: Date?, isHardLinked: Bool) {
            self.url = url
            self.logicalSize = logicalSize
            self.modificationDate = modificationDate
            self.isHardLinked = isHardLinked
        }

        public var displayName: String { url.lastPathComponent }
    }

    public let id: UUID
    public let logicalSize: Int64
    public let members: [Member]

    public init(id: UUID = UUID(), logicalSize: Int64, members: [Member]) {
        self.id = id
        self.logicalSize = logicalSize
        self.members = members
    }

    public var copyCount: Int { members.count }

    /// Bytes that go away if all but one copy are removed.
    public var wastedBytes: Int64 { logicalSize * Int64(members.count - 1) }

    /// The oldest member — the most likely original.
    public var primaryCopy: Member? {
        members.min { lhs, rhs in
            switch (lhs.modificationDate, rhs.modificationDate) {
            case let (l?, r?): return l < r
            case (nil, _?): return true
            case (_?, nil): return false
            case (nil, nil): return false
            }
        }
    }

    /// A stable fingerprint of the group's contents, used to persist user choices.
    public var fingerprint: String {
        let digest = SHA256Lite.sha256Hex(of: members.map { "\($0.url.path)|\($0.logicalSize)" }.joined(separator: "\n"))
        return "\(logicalSize)-\(members.count)-\(digest.prefix(16))"
    }
}

/// Set of files that could not be hashed, so the duplicate report can be honest
/// about its coverage.
public struct DuplicateScanCaveat: Sendable, Identifiable, Codable {
    public let url: URL
    public let reason: String

    public var id: URL { url }

    public init(url: URL, reason: String) {
        self.url = url
        self.reason = reason
    }
}

public struct DuplicateReport: Sendable {
    public let groups: [DuplicateGroup]
    public let bytesConsidered: Int64
    public let bytesSkippedForSpace: Int64
    public let caveats: [DuplicateScanCaveat]
    /// True when files under the size floor were never hashed at all.
    public let isPartial: Bool

    public init(
        groups: [DuplicateGroup] = [],
        bytesConsidered: Int64 = 0,
        bytesSkippedForSpace: Int64 = 0,
        caveats: [DuplicateScanCaveat] = [],
        isPartial: Bool = false
    ) {
        self.groups = groups
        self.bytesConsidered = bytesConsidered
        self.bytesSkippedForSpace = bytesSkippedForSpace
        self.caveats = caveats
        self.isPartial = isPartial
    }

    public var totalWastedBytes: Int64 { groups.reduce(0) { $0 + $1.wastedBytes } }

    public var totalFilesInGroups: Int { groups.reduce(0) { $0 + $1.copyCount } }

    public var isEmpty: Bool { groups.isEmpty }
}

/// An installed application, sized and dated.
public struct InstalledApp: Sendable, Identifiable, Codable {
    public let url: URL
    public let bundleIdentifier: String
    public let displayName: String
    public let version: String?
    public let logicalSize: Int64
    public let allocatedSize: Int64
    public let lastModification: Date?
    /// Best-effort "when did you last run this", from the launch services database.
    public let lastLaunched: Date?

    public var id: URL { url }

    public init(
        url: URL,
        bundleIdentifier: String,
        displayName: String,
        version: String?,
        logicalSize: Int64,
        allocatedSize: Int64,
        lastModification: Date?,
        lastLaunched: Date?
    ) {
        self.url = url
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
        self.version = version
        self.logicalSize = logicalSize
        self.allocatedSize = allocatedSize
        self.lastModification = lastModification
        self.lastLaunched = lastLaunched
    }

    /// Apps untouched for over a year are the interesting ones.
    public func isStale(referenceDate: Date = .now) -> Bool {
        let date = lastLaunched ?? lastModification
        guard let date else { return false }
        return date < referenceDate.addingTimeInterval(-365 * 24 * 60 * 60)
    }
}

/// Data left behind by an app that is no longer installed.
public struct OrphanedAppData: Sendable, Identifiable, Codable {
    public let ownerBundleIdentifier: String?
    public let displayName: String
    public let url: URL
    public let allocatedSize: Int64
    public let lastModification: Date?
    /// If we can name the app, we say so. If we cannot, we say "unknown app".
    public let confidence: Confidence

    public enum Confidence: String, Sendable, Codable {
        /// Bundle ID no longer matches any installed app.
        case confirmedOrphan
        /// Bundle ID matched, but the name on disk does not match any installed app either.
        case probableOrphan
        /// We could not determine ownership at all.
        case unknown

        public var label: String {
            switch self {
            case .confirmedOrphan: return "App is not installed"
            case .probableOrphan: return "Probably not installed"
            case .unknown: return "Owner unknown"
            }
        }
    }

    public var id: URL { url }

    public init(
        ownerBundleIdentifier: String?,
        displayName: String,
        url: URL,
        allocatedSize: Int64,
        lastModification: Date?,
        confidence: Confidence
    ) {
        self.ownerBundleIdentifier = ownerBundleIdentifier
        self.displayName = displayName
        self.url = url
        self.allocatedSize = allocatedSize
        self.lastModification = lastModification
        self.confidence = confidence
    }
}

/// The full app picture: what is installed, what is left behind.
public struct AppInventoryReport: Sendable {
    public let installed: [InstalledApp]
    public let orphans: [OrphanedAppData]
    public let scanLocations: [URL]

    public init(installed: [InstalledApp] = [], orphans: [OrphanedAppData] = [], scanLocations: [URL] = []) {
        self.installed = installed
        self.orphans = orphans
        self.scanLocations = scanLocations
    }

    public var totalInstalledSize: Int64 { installed.reduce(0) { $0 + $1.allocatedSize } }
    public var totalOrphanSize: Int64 { orphans.reduce(0) { $0 + $1.allocatedSize } }
    public var staleApps: [InstalledApp] { installed.filter { $0.isStale() } }

    public var isEmpty: Bool { installed.isEmpty && orphans.isEmpty }
}
