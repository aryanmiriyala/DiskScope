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

/// Build a report from a hand-made scan, so every expected total in the tests
/// below is derivable from the fixture itself rather than from a number that
/// could drift.
///
/// Declared at file scope rather than as a local helper because test bodies are
/// `@Sendable`, and Swift 6 will not let one capture a non-Sendable closure.
private func makeReport() -> BreakdownReport {
    let root = URL(fileURLWithPath: "/Users/example")
    let scan = ScanResult(
        roots: [root],
        directories: [
            // Caches: 1 GB of files directly here, plus a 500 MB child.
            DirectoryRecord(url: root.appending(path: "Library/Caches"), name: "Caches",
                            ownLogicalSize: 1_000_000_000, ownAllocatedSize: 1_000_000_000,
                            subtreeLogicalSize: 1_500_000_000, subtreeAllocatedSize: 1_500_000_000,
                            fileCount: 100, directoryCount: 2),
            DirectoryRecord(url: root.appending(path: "Library/Caches/com.example"), name: "com.example",
                            ownLogicalSize: 500_000_000, ownAllocatedSize: 500_000_000,
                            subtreeLogicalSize: 500_000_000, subtreeAllocatedSize: 500_000_000,
                            fileCount: 50, directoryCount: 1),
            // Trash, 2 GB.
            DirectoryRecord(url: root.appending(path: ".Trash"), name: ".Trash",
                            ownLogicalSize: 2_000_000_000, ownAllocatedSize: 2_000_000_000,
                            subtreeLogicalSize: 2_000_000_000, subtreeAllocatedSize: 2_000_000_000,
                            fileCount: 3, directoryCount: 1),
            // Documents, 4 GB, never deletable.
            DirectoryRecord(url: root.appending(path: "Documents"), name: "Documents",
                            ownLogicalSize: 4_000_000_000, ownAllocatedSize: 4_000_000_000,
                            subtreeLogicalSize: 4_000_000_000, subtreeAllocatedSize: 4_000_000_000,
                            fileCount: 200, directoryCount: 1),
            // An unrecognised folder, 300 MB.
            DirectoryRecord(url: root.appending(path: "MysteryFolder"), name: "MysteryFolder",
                            ownLogicalSize: 300_000_000, ownAllocatedSize: 300_000_000,
                            subtreeLogicalSize: 300_000_000, subtreeAllocatedSize: 300_000_000,
                            fileCount: 9, directoryCount: 1),
        ],
        scannedLogicalSize: 7_800_000_000,
        scannedAllocatedSize: 7_800_000_000
    )
    return BreakdownReport(scan: scan, classifier: LibraryClassifier(homeDirectory: root))
}

/// Tests for the report aggregator.
///
/// These check the arithmetic, because double counting is the failure mode that
/// would silently make every number in the app wrong while still looking
/// plausible.
func registerBreakdownTests() {

    test("breakdown: sums each file exactly once across categories") {
        let report = makeReport()
        // 1 GB (Caches) + 500 MB (com.example) + 2 GB (Trash) + 4 GB (Documents)
        // + 300 MB (Mystery) = 7.8 GB. Counting Caches' 1.5 GB subtree instead
        // of its own 1 GB would inflate the total to 8.3 GB.
        try expectEqual(report.totalAllocatedBytes, 7_800_000_000)
    }

    test("breakdown: categorises by path using self-contributed bytes only") {
        let report = makeReport()
        let caches = try require(report.categoryTotals.first { $0.category == .applicationCaches })
        // The child folder rolls up into the same category as its parent.
        try expectEqual(caches.allocatedSize, 1_500_000_000)

        let trash = try require(report.categoryTotals.first { $0.category == .trash })
        try expectEqual(trash.allocatedSize, 2_000_000_000)
    }

    test("breakdown: unknown folders are reported, not hidden") {
        let report = makeReport()
        let other = try require(report.categoryTotals.first { $0.category == .other })
        try expectEqual(other.allocatedSize, 300_000_000)
        try expectEqual(report.unexplainedBytes, 300_000_000)
    }

    test("breakdown: reclaimable total excludes anything not safe to delete") {
        let report = makeReport()
        // Trash 2 GB + app caches 1.5 GB. Documents are informational and the
        // 300 MB of unrecognised folders is destructive, so neither may appear
        // in the recoverable figure.
        try expectEqual(report.reclaimableBytes, 3_500_000_000)
    }

    test("breakdown: destructive data is never offered for deletion") {
        // `.destructive` sits below `.informational` in the raw ordering, so a
        // naive `risk < .informational` check would wrongly mark it deletable.
        try expect(!RiskLevel.destructive.isDeletable)
        try expect(!RiskLevel.informational.isDeletable)
        try expect(RiskLevel.caution.isDeletable)
        try expect(RiskLevel.regenerable.isDeletable)
        try expect(!RiskLevel.regenerable.requiresExplicitConfirmation)
    }

    test("breakdown: a category containing anything destructive is not marked safe") {
        // If any directory under a category is destructive, the whole category
        // must not be presented as safe, or the user could clear a bucket that
        // had their mail in it.
        let root = URL(fileURLWithPath: "/Users/example")
        let scan = ScanResult(
            roots: [root],
            directories: [
                DirectoryRecord(url: root.appending(path: "Library/Mail"), name: "Mail",
                                ownAllocatedSize: 100_000_000, subtreeAllocatedSize: 100_000_000),
                DirectoryRecord(url: root.appending(path: "Library/Mail/V9"), name: "V9",
                                ownAllocatedSize: 900_000_000, subtreeAllocatedSize: 900_000_000),
            ]
        )
        let report = BreakdownReport(scan: scan, classifier: LibraryClassifier(homeDirectory: root))
        let mail = try require(report.categoryTotals.first { $0.category == .mail })
        try expectEqual(mail.risk, .destructive, "mail must not inherit a safe label from a sibling")
    }

    test("breakdown: top level lists only direct children of the roots") {
        let report = makeReport()
        let names = Set(report.topLevel.map(\.name))
        try expect(names.contains("Library") || names.contains(".Trash"))
        // The nested com.example must not appear as a top-level entry.
        try expect(!report.topLevel.contains { $0.name == "com.example" })
    }

    test("breakdown: reclaimable directories never include informational categories") {
        let report = makeReport()
        let paths = report.reclaimableDirectories.map(\.url.path)
        try expect(!paths.contains { $0.contains("Documents") }, "documents are never a deletion target")
        try expect(paths.contains { $0.contains(".Trash") })
    }

    test("breakdown: empty directories contribute nothing rather than adding noise") {
        let root = URL(fileURLWithPath: "/Users/example")
        let scan = ScanResult(
            roots: [root],
            directories: [
                DirectoryRecord(url: root, name: "example"),
                DirectoryRecord(url: root.appending(path: "Empty"), name: "Empty"),
            ]
        )
        let report = BreakdownReport(scan: scan, classifier: LibraryClassifier(homeDirectory: root))
        try expectEqual(report.totalAllocatedBytes, 0)
    }

    test("breakdown: best first step prefers high-value easy wins over raw size") {
        // Trash is smaller than Documents but is the better suggestion, and
        // Documents is not deletable at all.
        let report = makeReport()
        let step = try require(report.bestFirstStep)
        try expectEqual(step.category, .trash)
    }
}
