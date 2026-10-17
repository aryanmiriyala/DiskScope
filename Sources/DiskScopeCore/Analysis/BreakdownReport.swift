import Foundation

/// Turns a completed scan into the answered question: "where did it go?"
///
/// The interesting problem here is double counting. A `DirectoryRecord` carries
/// its whole subtree's size, so summing every record would count each byte once
/// per ancestor and produce nonsense. Everything below works from
/// `ownAllocatedSize` — the bytes contributed by files sitting *directly* in
/// that directory — and rolls them up. Every file is therefore counted exactly
/// once, by the directory that contains it.
///
/// The other thing this type is careful about is refusing to hide anything.
/// A category called "Other" is reported with the same prominence as a
/// recognised one, because a classifier that quietly dumps the awkward 4% into a
/// bucket is the same failure mode as an unreadable directory reported as empty.
public struct BreakdownReport: Sendable {
    public let scan: ScanResult
    public let classifier: LibraryClassifier

    /// Totals per category, largest first.
    public let categoryTotals: [CategoryTotal]

    /// Direct children of each scan root, largest first. This is the intuitive
    /// top-level view: it is what "what is in my home folder" means.
    public let topLevel: [DirectoryRecord]

    /// The directories a user is most likely to want to act on, largest first.
    public let reclaimableDirectories: [DirectoryRecord]

    public init(scan: ScanResult, classifier: LibraryClassifier = LibraryClassifier()) {
        self.scan = scan
        self.classifier = classifier

        // Bucket by category using only self-contributed bytes.
        var logical: [DiskCategory: Int64] = [:]
        var allocated: [DiskCategory: Int64] = [:]
        var counts: [DiskCategory: Int] = [:]
        var risk: [DiskCategory: RiskLevel] = [:]
        var samples: [DiskCategory: [URL]] = [:]

        for record in scan.directories {
            // An empty directory has no bytes of its own; there is nothing to
            // attribute and it would only add noise.
            guard record.ownAllocatedSize > 0 || record.ownLogicalSize > 0 else { continue }

            let classification = classifier.classify(path: record.url.path)
            let category = classification.category

            logical[category, default: 0] += record.ownLogicalSize
            allocated[category, default: 0] += record.ownAllocatedSize
            counts[category, default: 0] += 1

            // Keep the strictest risk seen in the category. If any directory in
            // here is destructive, the whole category must not be presented as
            // safe to clear.
            let existing = risk[category]
            risk[category] = max(existing ?? classification.risk, classification.risk)

            if samples[category, default: []].count < 5 {
                samples[category, default: []].append(record.url)
            }
        }

        self.categoryTotals = DiskCategory.allCases.compactMap { category in
            guard let bytes = allocated[category], bytes > 0 else { return nil }
            return CategoryTotal(
                category: category,
                logicalSize: logical[category] ?? 0,
                allocatedSize: bytes,
                itemCount: counts[category] ?? 0,
                risk: risk[category] ?? category.defaultRisk,
                samplePaths: samples[category] ?? []
            )
        }
        .sorted { $0.allocatedSize > $1.allocatedSize }

        // Direct children of the roots, for the top-level view.
        let rootPaths = Set(scan.roots.map { $0.standardizedFileURL.resolvingSymlinksInPath().path })
        self.topLevel = scan.directories
            .filter { record in
                let parent = record.url.deletingLastPathComponent()
                    .standardizedFileURL
                    .resolvingSymlinksInPath()
                    .path
                return rootPaths.contains(parent)
            }
            .sorted { $0.subtreeAllocatedSize > $1.subtreeAllocatedSize }

        // Anything deletable, biggest first. Informational categories are
        // excluded entirely so this list can never suggest removing something
        // that is not safe to remove.
        self.reclaimableDirectories = scan.directories
            .filter { record in
                guard record.subtreeAllocatedSize > 0 else { return false }
                return classifier.classify(path: record.url.path).risk.isDeletable
            }
            .sorted { $0.subtreeAllocatedSize > $1.subtreeAllocatedSize }
    }

    /// Physical bytes attributed across all categories.
    public var totalAllocatedBytes: Int64 {
        categoryTotals.reduce(0) { $0 + $1.allocatedSize }
    }

    /// Physical bytes DiskScope is willing to offer for removal.
    public var reclaimableBytes: Int64 {
        categoryTotals.reduce(0) { $0 + $1.reclaimableSize }
    }

    /// Directories the rule table could not explain.
    ///
    /// Surfaced deliberately. This is the list the AI grouping feature exists to
    /// shrink, so hiding it would hide the tool's own progress.
    public var unexplained: CategoryTotal? {
        categoryTotals.first { $0.category == .other }
    }

    public var unexplainedBytes: Int64 { unexplained?.allocatedSize ?? 0 }

    /// The single highest-value thing to do, if the user wants one suggestion.
    ///
    /// Ranked by the category's own reclaim priority rather than by size alone,
    /// because emptying a 4 GB Trash bin is a better suggestion than clearing
    /// 4 GB of browser cache that will simply refill.
    public var bestFirstStep: CategoryTotal? {
        categoryTotals
            .filter { $0.risk.isDeletable && $0.reclaimableSize > 0 }
            .max { lhs, rhs in
                let lhsScore = Double(lhs.reclaimableSize) * Double(lhs.category.reclaimPriority)
                let rhsScore = Double(rhs.reclaimableSize) * Double(rhs.category.reclaimPriority)
                return lhsScore < rhsScore
            }
    }

    /// Bytes the scanner could not account for.
    ///
    /// A non-zero value here means the breakdown does not add up to what
    /// Finder reports, and the reason is almost always the denial list.
    public func unaccountedBytes(volume: VolumeUsage?) -> Int64? {
        guard let volume else { return nil }
        // Only meaningful when the scan covered a whole volume.
        return volume.usedBytes - totalAllocatedBytes
    }
}
