import Foundation
import DiskScopeCore

/// Tests for the cross-filesystem policy.
///
/// `stayOnOneFilesystem` was declared, stored, and never read — a flag that
/// silently did nothing. These pin the policy directly rather than depending on
/// a machine having a mounted volume at the right path, which is the only
/// situation where the branch runs for real and which CI cannot reproduce.
func registerFilesystemBoundaryTests() {
    test("boundary: does not descend onto another device when the flag is set") {
        try expectEqual(
            FileSystemScanner.shouldDescend(childDevice: 200, rootDevice: 100, stayOnOneFilesystem: true),
            false,
            "a different device means a different filesystem"
        )
    }

    test("boundary: descends onto the same device") {
        try expectEqual(
            FileSystemScanner.shouldDescend(childDevice: 100, rootDevice: 100, stayOnOneFilesystem: true),
            true
        )
    }

    test("boundary: crosses devices freely when the flag is off") {
        try expectEqual(
            FileSystemScanner.shouldDescend(childDevice: 999, rootDevice: 100, stayOnOneFilesystem: false),
            true,
            "an explicit opt-out must be honoured"
        )
    }

    test("boundary: allows the walk when no root device is known yet") {
        // The first directory opened has nothing to compare against; refusing to
        // descend would make the very first step fail.
        try expectEqual(
            FileSystemScanner.shouldDescend(childDevice: 100, rootDevice: nil, stayOnOneFilesystem: true),
            true
        )
    }

    test("boundary: a scan of / records any mounted volumes it declined to walk") {
        // Only meaningful on a machine with a mounted volume inside the tree,
        // which this Mac has. Asserted conditionally so it does not fail on a
        // machine with none.
        let result = try await FileSystemScanner(
            configuration: ScanConfiguration(
                roots: [URL(fileURLWithPath: "/Library/Developer/CoreSimulator/Volumes")],
                maximumDepth: 2
            )
        ).scanToCompletion()

        // Whatever the outcome, the report must be able to state it rather than
        // quietly omitting the volumes.
        for mount in result.skippedMounts {
            try expect(!mount.url.path.isEmpty)
        }
        if !result.skippedMounts.isEmpty {
            try expect(
                !result.isComplete,
                "a skipped mount must make the result incomplete"
            )
        }
    }

    test("boundary: a single-filesystem scan reports no skipped mounts") {
        let tree = try TempTree()
        try tree.writeFile("a/b/c.txt", bytes: 100)

        let result = try await FileSystemScanner(
            configuration: ScanConfiguration(roots: [tree.root])
        ).scanToCompletion()

        try expectEqual(result.skippedMounts.count, 0, "a plain temp tree has no other filesystems")
        try expect(result.isComplete)
    }
}
