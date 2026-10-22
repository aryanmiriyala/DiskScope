// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Aryan Miriyala
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import Foundation
import Darwin
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

    test("scanner: the bulk path and the one-at-a-time path report the same numbers") {
        let tree = try TempTree()
        try tree.writeFile("a.txt", bytes: 1_000)
        try tree.writeFile("sub/b.txt", bytes: 2_000)
        try tree.writeFile("sub/deeper/c.txt", bytes: 3_000)
        try tree.writeFile("empty.txt", bytes: 0)
        try tree.writeFile("linked.txt", bytes: 1_500)
        try FileManager.default.linkItem(
            at: tree.url("linked.txt"),
            to: tree.url("linked-alias.txt")
        )
        try FileManager.default.createSymbolicLink(
            at: tree.url("link-to-dir"),
            withDestinationURL: tree.url("sub")
        )

        func scan(useBulkAttributes: Bool) async throws -> ScanResult {
            try await FileSystemScanner(
                configuration: ScanConfiguration(
                    roots: [tree.root],
                    largeFileThreshold: 1,
                    maximumLargeFiles: 10_000,
                    useBulkAttributes: useBulkAttributes
                )
            ).scanToCompletion()
        }

        let bulk = try await scan(useBulkAttributes: true)
        let oneAtATime = try await scan(useBulkAttributes: false)

        try expectEqual(bulk.scannedLogicalSize, oneAtATime.scannedLogicalSize)
        try expectEqual(bulk.scannedAllocatedSize, oneAtATime.scannedAllocatedSize)
        try expectEqual(bulk.directories.count, oneAtATime.directories.count)
        try expectEqual(bulk.largeFiles.count, oneAtATime.largeFiles.count)

        // Same files, same sizes, same inodes.
        let bulkFiles = Set(bulk.largeFiles.map { "\($0.url.path):\($0.logicalSize):\($0.inode)" })
        let fallbackFiles = Set(oneAtATime.largeFiles.map { "\($0.url.path):\($0.logicalSize):\($0.inode)" })
        try expectEqual(bulkFiles, fallbackFiles)

        let bulkRoot = try require(bulk.directories.first { $0.url == tree.root })
        let fallbackRoot = try require(oneAtATime.directories.first { $0.url == tree.root })
        try expectEqual(bulkRoot.fileCount, fallbackRoot.fileCount)
        try expectEqual(bulkRoot.symlinkCount, fallbackRoot.symlinkCount)
        try expectEqual(bulkRoot.subtreeLogicalSize, fallbackRoot.subtreeLogicalSize)
        try expectEqual(bulkRoot.subtreeAllocatedSize, fallbackRoot.subtreeAllocatedSize)
    }

    test("scanner: a directory too big for the bulk buffer is still counted in full") {
        let tree = try TempTree()
        // The bulk buffer holds roughly two and a half thousand entries. A
        // directory with more than that cannot be read in one call, so the
        // scanner has to fall back to reading it the slow way rather than
        // report the entries it happened to see.
        let count = 4_000
        for index in 0..<count {
            let fd = open(tree.url("f\(index)").path, O_CREAT | O_WRONLY | O_EXCL, 0o644)
            try expect(fd >= 0, "could not create the test file")
            close(fd)
        }

        let result = try await FileSystemScanner(
            configuration: ScanConfiguration(
                roots: [tree.root],
                largeFileThreshold: 0,
                maximumLargeFiles: 10_000
            )
        ).scanToCompletion()

        let root = try require(result.directories.first { $0.url == tree.root })
        try expectEqual(root.fileCount, count, "every file in a large directory is counted")
        try expectEqual(result.largeFiles.count, count)
    }
}
