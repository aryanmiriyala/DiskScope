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
import DiskScopeCore

/// Scan a tree with the duplicate finder in mind.
///
/// The finder works from the scan's own file table, so the scan has to record
/// every file the finder might care about. That means the scan's threshold
/// cannot be above the finder's minimum size.
private func scanTreeForDuplicates(root: URL, minimumSize: Int64 = 1) async throws -> ScanResult {
    try await FileSystemScanner(
        configuration: ScanConfiguration(
            roots: [root],
            largeFileThreshold: minimumSize,
            maximumLargeFiles: 200_000,
            skipGitInternals: true
        )
    ).scanToCompletion()
}

func registerDuplicateFinderTests() {
    test("duplicates: identical files in different directories are found") {
        let tree = try TempTree()
        try tree.writeFile("one.txt", bytes: 4_096)
        try tree.writeFile("two.txt", bytes: 4_096)
        try tree.writeFile("nested/three.txt", bytes: 4_096)

        let scan = try await scanTreeForDuplicates(root: tree.root)
        let result = await DuplicateFinder(
            configuration: DuplicateFinderConfiguration(minimumSize: 1)
        ).findDuplicates(in: scan)

        try expectEqual(result.groups.count, 1, "one group of three copies")
        let group = try require(result.groups.first)
        try expectEqual(group.memberCount, 3)
        try expectEqual(group.logicalSize, 4_096)
        try expectEqual(
            Set(group.members.map(\.url.lastPathComponent)),
            ["one.txt", "two.txt", "three.txt"]
        )
    }

    test("duplicates: files of the same size but different content are not duplicates") {
        let tree = try TempTree()
        // Same length, different bytes. The sample hash has to tell them
        // apart even though the size grouping cannot.
        try Data(repeating: 0x41, count: 8_192).write(to: tree.url("a.bin"))
        try Data(repeating: 0x42, count: 8_192).write(to: tree.url("b.bin"))

        let scan = try await scanTreeForDuplicates(root: tree.root)
        let result = await DuplicateFinder(
            configuration: DuplicateFinderConfiguration(minimumSize: 1)
        ).findDuplicates(in: scan)

        try expectEqual(result.groups.count, 0, "different content is not a duplicate")
    }

    test("duplicates: a file that differs only in its middle is still not a duplicate") {
        let tree = try TempTree()
        // The head and the tail are identical, so the sample hash collides
        // and the full hash has to settle it.
        let original = Data(repeating: 0x41, count: 200_000)
        var changed = original
        changed[100_000..<110_000] = Data(repeating: 0x42, count: 10_000)
        try original.write(to: tree.url("a.bin"))
        try changed.write(to: tree.url("b.bin"))

        let scan = try await scanTreeForDuplicates(root: tree.root)
        let result = await DuplicateFinder(
            configuration: DuplicateFinderConfiguration(minimumSize: 1)
        ).findDuplicates(in: scan)

        try expectEqual(result.groups.count, 0, "a shared head and tail is not a shared file")
    }

    test("duplicates: files below the minimum size are not considered") {
        let tree = try TempTree()
        try tree.writeFile("small.txt", bytes: 100)
        try tree.writeFile("small2.txt", bytes: 100)

        let scan = try await scanTreeForDuplicates(root: tree.root, minimumSize: 1_024)
        let result = await DuplicateFinder(
            configuration: DuplicateFinderConfiguration(minimumSize: 1_024)
        ).findDuplicates(in: scan)

        try expectEqual(result.groups.count, 0, "small files are out of scope")
    }

    test("duplicates: the reported digest matches the file's own SHA-256") {
        let tree = try TempTree()
        try tree.writeFile("a.txt", bytes: 4_096)
        try tree.writeFile("b.txt", bytes: 4_096)

        let scan = try await scanTreeForDuplicates(root: tree.root)
        let result = await DuplicateFinder(
            configuration: DuplicateFinderConfiguration(minimumSize: 1)
        ).findDuplicates(in: scan)

        let group = try require(result.groups.first)
        try expectEqual(group.contentDigest, shellSHA256(ofFileAt: tree.url("a.txt")))
    }

    test("duplicates: reclaimable space counts the copies that would go away") {
        let tree = try TempTree()
        try tree.writeFile("a.txt", bytes: 4_096)
        try tree.writeFile("b.txt", bytes: 4_096)
        try tree.writeFile("c.txt", bytes: 4_096)

        let scan = try await scanTreeForDuplicates(root: tree.root)
        let result = await DuplicateFinder(
            configuration: DuplicateFinderConfiguration(minimumSize: 1)
        ).findDuplicates(in: scan)

        let group = try require(result.groups.first)
        // Three copies of one file: keeping one releases the space of the
        // other two.
        let allocated = try require(group.members.first).allocatedSize
        try expectEqual(group.wastedBytes, allocated * 2)
        try expectEqual(result.totalWastedBytes, allocated * 2)
        try expectEqual(group.distinctInodeCount, 3, "three separate files")
    }

    test("duplicates: hard links are not offered as reclaimable space") {
        let tree = try TempTree()
        try tree.writeFile("original.txt", bytes: 4_096)
        // A second name for the same file. Deleting it frees nothing, because
        // the blocks are still reachable through the first name.
        try FileManager.default.linkItem(at: tree.url("original.txt"), to: tree.url("hardlink.txt"))

        let scan = try await scanTreeForDuplicates(root: tree.root)
        let result = await DuplicateFinder(
            configuration: DuplicateFinderConfiguration(minimumSize: 1)
        ).findDuplicates(in: scan)

        let group = try require(result.groups.first)
        try expectEqual(group.memberCount, 2, "both names are reported")
        try expectEqual(group.distinctInodeCount, 1, "but they are one file")
        try expectEqual(group.wastedBytes, 0, "a hard link releases no space")
    }

    test("duplicates: a scan that never recorded small files says so") {
        let tree = try TempTree()
        try tree.writeFile("a.txt", bytes: 4_096)
        try tree.writeFile("b.txt", bytes: 4_096)

        // The scan's threshold is above the finder's minimum size, so the
        // smaller files were never recorded and cannot be examined.
        let scan = try await scanTreeForDuplicates(root: tree.root, minimumSize: 64 * 1024)
        let result = await DuplicateFinder(
            configuration: DuplicateFinderConfiguration(minimumSize: 1)
        ).findDuplicates(in: scan)

        try expectEqual(result.groups.count, 0)
        try expect(result.caveats.contains { $0.reason.contains("smaller duplicates") })
    }

    test("duplicates: the hashing limit is reported rather than silently applied") {
        let tree = try TempTree()
        for index in 0..<6 {
            try tree.writeFile("copy\(index).txt", bytes: 4_096)
        }

        // A budget of three cannot cover a group of six.
        let scan = try await scanTreeForDuplicates(root: tree.root)
        let result = await DuplicateFinder(
            configuration: DuplicateFinderConfiguration(minimumSize: 1, maxFilesToHash: 3)
        ).findDuplicates(in: scan)

        try expect(result.isPartial, "the result should be marked partial")
        try expect(result.caveats.contains { $0.reason.contains("not examined") })
    }

    test("duplicates: an empty tree finds nothing") {
        let tree = try TempTree()

        let scan = try await scanTreeForDuplicates(root: tree.root)
        let result = await DuplicateFinder(
            configuration: DuplicateFinderConfiguration(minimumSize: 1)
        ).findDuplicates(in: scan)

        try expectEqual(result.groups.count, 0)
        try expect(result.isEmpty)
        try expectEqual(result.totalWastedBytes, 0)
    }
}
