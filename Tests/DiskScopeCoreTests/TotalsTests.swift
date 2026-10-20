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

/// Guards against totals that are plausible but wrong.
///
/// A subtree count summed across every directory counts each file once per
/// ancestor. On a real home directory that inflated the reported file total by
/// roughly seven times, while every other number stayed plausible — which is
/// the most dangerous kind of bug for a tool whose whole purpose is being
/// trustworthy about numbers.
func registerTotalsTests() {
    test("totals: a file is counted once, not once per ancestor directory") {
        let tree = try TempTree()
        try tree.writeFile("a.txt", bytes: 100)
        try tree.writeFile("one/two/three/deep.txt", bytes: 100)
        try tree.writeFile("one/two/other.txt", bytes: 100)

        let result = try await FileSystemScanner(
            configuration: ScanConfiguration(roots: [tree.root])
        ).scanToCompletion()

        // Three files: a.txt, one/two/other.txt, one/two/three/deep.txt. Depth
        // here is 5, so summing subtree counts would report well over 12.
        try expectEqual(result.fileCount, 3, "each file is counted exactly once")
        try expectEqual(result.totalDirectoryCount, 4, "root, one, two, three")
    }

    test("totals: directory count matches the records, not the tree depth") {
        let tree = try TempTree()
        try tree.writeFile("x/y/z/w/deep.txt", bytes: 50)

        let result = try await FileSystemScanner(
            configuration: ScanConfiguration(roots: [tree.root])
        ).scanToCompletion()

        // root + x + y + z + w = 5 directories. Not 5 * depth.
        try expectEqual(result.totalDirectoryCount, 5)
    }

    test("totals: byte total equals the sum of files actually present") {
        let tree = try TempTree()
        try tree.writeFile("a.bin", bytes: 10_000)
        try tree.writeFile("sub/b.bin", bytes: 20_000)
        try tree.writeFile("sub/deep/c.bin", bytes: 30_000)

        let result = try await FileSystemScanner(
            configuration: ScanConfiguration(roots: [tree.root])
        ).scanToCompletion()

        let root = try require(result.directories.first { $0.url == tree.root })
        // 60,000 bytes of file content. Directory inodes add a little, so assert
        // the lower bound and that it is nowhere near double counting.
        try expectGreaterThanOrEqual(root.subtreeLogicalSize, 60_000)
        try expectLessThan(root.subtreeLogicalSize, 120_000)
    }

    test("totals: a deep single file is not multiplied by its depth") {
        // The specific shape that broke the old summation: one file, many
        // ancestors. Summing subtree counts here gives depth * size.
        let tree = try TempTree()
        try tree.writeFile("a/b/c/d/e/f/g/leaf.bin", bytes: 5_000)

        let result = try await FileSystemScanner(
            configuration: ScanConfiguration(roots: [tree.root])
        ).scanToCompletion()

        let root = try require(result.directories.first { $0.url == tree.root })
        try expectLessThan(
            root.subtreeLogicalSize,
            20_000,
            "one 5 KB file must not become 35 KB because of nesting depth"
        )
        try expectEqual(result.fileCount, 1)
    }
}
