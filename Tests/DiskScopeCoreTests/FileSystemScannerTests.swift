import Foundation
import DiskScopeCore

func registerScannerTests() {
    test("scanner: reports logical size across a nested tree") {
        let tree = try TempTree()
        try tree.writeFile("a.txt", bytes: 1_000)
        try tree.writeFile("sub/b.txt", bytes: 2_000)
        try tree.writeFile("sub/deeper/c.txt", bytes: 3_000)

        let result = try await FileSystemScanner(
            configuration: ScanConfiguration(roots: [tree.root])
        ).scanToCompletion()

        // 6,000 bytes of file content plus whatever the directory inodes cost.
        // Asserting on the file-derived portion keeps this insensitive to
        // directory block allocation, which varies by filesystem.
        let root = try require(
            result.directories.first { $0.url == tree.root },
            "root directory should have a record"
        )
        try expectGreaterThanOrEqual(root.subtreeLogicalSize, 6_000)
        try expectEqual(root.fileCount, 3, "three files total")
        try expectEqual(root.directoryCount, 3, "root, sub, sub/deeper")

        let deeper = try require(
            result.directories.first { $0.url.path.hasSuffix("sub/deeper") }
        )
        try expectEqual(deeper.subtreeLogicalSize, 3_000)
        try expectEqual(deeper.fileCount, 1)
    }

    test("scanner: allocated size is reported and never below logical size") {
        let tree = try TempTree()
        try tree.writeFile("blob.bin", bytes: 100_000)

        let result = try await FileSystemScanner(
            configuration: ScanConfiguration(roots: [tree.root])
        ).scanToCompletion()

        let record = try require(result.directories.first { $0.url == tree.root })
        try expect(record.subtreeAllocatedSize > 0, "physical size should be non-zero")
        try expectGreaterThanOrEqual(record.subtreeAllocatedSize, record.subtreeLogicalSize)
    }

    test("scanner: symlinks are never followed and are not counted as files") {
        let tree = try TempTree()
        try tree.writeFile("real/inner.txt", bytes: 5_000)

        try FileManager.default.createSymbolicLink(
            at: tree.url( "link-to-real"),
            withDestinationURL: tree.url( "real")
        )

        let result = try await FileSystemScanner(
            configuration: ScanConfiguration(roots: [tree.root])
        ).scanToCompletion()

        let root = try require(result.directories.first { $0.url == tree.root })
        // Only the one real file. A scanner that followed the link would report
        // 2 files and roughly double the bytes.
        try expectEqual(root.fileCount, 1, "the link must not cause a second traversal")
        try expectEqual(root.symlinkCount, 1, "the link is tracked separately")
        try expectGreaterThanOrEqual(root.subtreeLogicalSize, 5_000)
        try expectLessThan(root.subtreeLogicalSize, 10_000)
    }

    test("scanner: a symlink loop terminates instead of hanging") {
        let tree = try TempTree()
        _ = try tree.makeDirectory("dir")
        try FileManager.default.createSymbolicLink(
            at: tree.url( "dir/loop"),
            withDestinationURL: tree.url( "dir")
        )

        let result = try await FileSystemScanner(
            configuration: ScanConfiguration(roots: [tree.root], maximumDepth: 16)
        ).scanToCompletion()

        try expect(result.directories.count >= 1)
    }

    test("scanner: excluded paths are skipped entirely") {
        let tree = try TempTree()
        try tree.writeFile("keep.txt", bytes: 1_000)
        try tree.writeFile("skipme/big.bin", bytes: 500_000)

        let result = try await FileSystemScanner(configuration: ScanConfiguration(
            roots: [tree.root],
            excludedPaths: [tree.url( "skipme").path]
        )).scanToCompletion()

        try expect(
            !result.directories.contains { $0.url.path.hasSuffix("skipme") },
            "excluded directory should not appear"
        )
    }

    test("scanner: collects only files over the size threshold") {
        let tree = try TempTree()
        try tree.writeFile("huge.bin", bytes: 250_000)
        try tree.writeFile("tiny.bin", bytes: 10)

        let result = try await FileSystemScanner(configuration: ScanConfiguration(
            roots: [tree.root],
            largeFileThreshold: 100_000
        )).scanToCompletion()

        try expectEqual(result.largeFiles.count, 1)
        try expectEqual(result.largeFiles.first?.url.lastPathComponent, "huge.bin")
    }

    test("scanner: hard links to one file are counted once") {
        let tree = try TempTree()
        let original = tree.url( "original.bin")
        try Data(repeating: 0x42, count: 300_000).write(to: original)
        try FileManager.default.linkItem(at: original, to: tree.url( "link1.bin"))
        try FileManager.default.linkItem(at: original, to: tree.url( "link2.bin"))

        let result = try await FileSystemScanner(
            configuration: ScanConfiguration(roots: [tree.root])
        ).scanToCompletion()

        let record = try require(result.directories.first { $0.url == tree.root })
        // Three paths, 300 KB of data. Counting per-path would report ~900 KB.
        try expectLessThan(record.subtreeLogicalSize, 600_000)
        try expectEqual(result.deduplicatedHardLinks, 2)
    }

    test("scanner: unreadable directories become denial records, not silent zeros") {
        let tree = try TempTree()
        try tree.writeFile("ok.txt", bytes: 100)
        let blocked = try tree.makeDirectory("blocked")
        try tree.writeFile("blocked/secret.txt", bytes: 1_000_000)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: blocked.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: blocked.path)
        }

        let result = try await FileSystemScanner(
            configuration: ScanConfiguration(roots: [tree.root])
        ).scanToCompletion()

        // Running as root would defeat the chmod, so only assert when the
        // permission actually bites.
        if !FileManager.default.isReadableFile(atPath: blocked.path) {
            try expect(
                result.deniedPaths.contains { $0.url.path == blocked.path },
                "denial should be recorded, not swallowed"
            )
            try expect(!result.isComplete)
            try expect(result.hasPermissionDenials)
        }
    }

    test("scanner: a missing root is reported as a denial, not a crash") {
        let missing = URL(fileURLWithPath: "/tmp/diskscope-definitely-not-here-\(UUID().uuidString)")
        let result = try await FileSystemScanner(
            configuration: ScanConfiguration(roots: [missing])
        ).scanToCompletion()

        try expect(result.deniedPaths.contains { $0.url == missing })
    }

    test("scanner: .git internals are skipped when asked") {
        let tree = try TempTree()
        try tree.writeFile("repo/.git/objects/bigpack", bytes: 400_000)
        try tree.writeFile("repo/src/main.swift", bytes: 1_200)

        let result = try await FileSystemScanner(configuration: ScanConfiguration(
            roots: [tree.root],
            skipGitInternals: true
        )).scanToCompletion()

        let root = try require(result.directories.first { $0.url == tree.root })
        try expectLessThan(
            root.subtreeLogicalSize,
            200_000,
            "the .git pack should not be counted"
        )
    }
}
