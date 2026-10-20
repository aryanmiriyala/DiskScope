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

/// Tests for the disk reconciliation.
///
/// The arithmetic is the whole point of this type. A reconciliation that adds up
/// wrongly is worse than no reconciliation, because it would give the user a
/// confident explanation of a number that does not hold.
/// A synthetic volume with a known used/total split.
///
/// File scope rather than a local helper because test bodies are `@Sendable` and
/// Swift 6 will not let one capture a non-Sendable closure.
private func volume(total: Int64, used: Int64) -> VolumeUsage {
    VolumeUsage(
        volumeName: "Macintosh HD",
        mountPoint: "/",
        totalBytes: total,
        freeBytes: total - used,
        availableBytes: total - used
    )
}

func registerAccountingTests() {
    test("accounting: a fully explained disk reports nothing unexplained") {
        let accounting = DiskAccounting(
            volume: volume(total: 500_000_000_000, used: 100_000_000_000),
            scannedBytes: 100_000_000_000
        )
        try expectEqual(accounting.unexplainedBytes, 0)
        try expect(accounting.isReconciled())
        try expect(accounting.verdict.contains("accounted for"))
    }

    test("accounting: a large gap is flagged rather than excused") {
        let accounting = DiskAccounting(
            volume: volume(total: 500_000_000_000, used: 200_000_000_000),
            scannedBytes: 120_000_000_000
        )
        try expectEqual(accounting.unexplainedBytes, 80_000_000_000)
        try expect(!accounting.isReconciled(), "40% unaccounted cannot be called metadata")
        try expect(accounting.verdict.contains("too large to be metadata"))
    }

    test("accounting: a small gap is treated as normal") {
        // 1% remainder: directory inodes and unreclaimed space.
        let accounting = DiskAccounting(
            volume: volume(total: 500_000_000_000, used: 100_000_000_000),
            scannedBytes: 99_000_000_000
        )
        try expectEqual(accounting.unexplainedBytes, 1_000_000_000)
        try expect(accounting.isReconciled(), "1% is expected noise")
        try expect(accounting.verdict.contains("normal"))
    }

    test("accounting: scanned size larger than reported never goes negative") {
        // Should not happen, but a negative remainder would print as nonsense.
        let accounting = DiskAccounting(
            volume: volume(total: 500_000_000_000, used: 50_000_000_000),
            scannedBytes: 80_000_000_000
        )
        try expectEqual(accounting.unexplainedBytes, 0, "must clamp at zero, not go negative")
        try expectEqual(accounting.unexplainedFraction(), 0)
    }

    test("accounting: a zero-sized volume does not divide by zero") {
        let accounting = DiskAccounting(
            volume: volume(total: 0, used: 0),
            scannedBytes: 0
        )
        try expectEqual(accounting.unexplainedFraction(), nil)
        try expect(accounting.isReconciled())
        try expect(accounting.verdict.contains("No volume figures"))
    }

    test("accounting: snapshots are reported without an invented size") {
        let accounting = DiskAccounting(
            volume: volume(total: 500_000_000_000, used: 200_000_000_000),
            scannedBytes: 120_000_000_000,
            localSnapshotCount: 7
        )
        let snapshotLines = accounting.reconciliation.filter { $0.text.contains("snapshot") }
        try expectEqual(snapshotLines.count, 1)
        try expect(
            snapshotLines[0].bytes == nil,
            "a snapshot size must never be estimated"
        )
        try expect(snapshotLines[0].kind == .known)
    }

    test("accounting: purgeable space is labelled as a macOS figure, not ours") {
        let accounting = DiskAccounting(
            volume: volume(total: 500_000_000_000, used: 200_000_000_000),
            scannedBytes: 120_000_000_000,
            purgeableBytes: 15_000_000_000
        )
        let purgeLine = try require(accounting.reconciliation.first { $0.text.contains("purgeable") })
        try expectEqual(purgeLine.kind, .reported, "we did not measure this; macOS reported it")
        try expectEqual(purgeLine.bytes, 15_000_000_000)
    }

    test("accounting: volumes sharing the pool are called out") {
        let accounting = DiskAccounting(
            volume: volume(total: 500_000_000_000, used: 200_000_000_000),
            scannedBytes: 120_000_000_000,
            otherVolumes: [
                VolumeUsage(volumeName: "Preboot", mountPoint: "/System/Volumes/Preboot",
                            totalBytes: 500_000_000_000, freeBytes: 480_000_000_000, availableBytes: 480_000_000_000),
                VolumeUsage(volumeName: "Stick", mountPoint: "/Volumes/Stick",
                            totalBytes: 64_000_000_000, freeBytes: 60_000_000_000, availableBytes: 60_000_000_000),
            ]
        )
        let poolLine = try require(accounting.reconciliation.first { $0.text.contains("share this") })
        try expect(poolLine.text.contains("Preboot"), "same-pool volume should be named")
        try expect(!poolLine.text.contains("Stick"), "a separate external disk is not pool sharing")
    }

    test("accounting: every reconciliation line is measured, reported, derived or known") {
        // Guards against a future line being added that asserts a cause with no
        // provenance.
        let accounting = DiskAccounting(
            volume: volume(total: 500_000_000_000, used: 200_000_000_000),
            scannedBytes: 120_000_000_000,
            purgeableBytes: 5_000_000_000,
            localSnapshotCount: 3,
            otherVolumes: [
                VolumeUsage(volumeName: "Preboot", mountPoint: "/System/Volumes/Preboot",
                            totalBytes: 500_000_000_000, freeBytes: 400_000_000_000, availableBytes: 400_000_000_000),
            ]
        )
        let lines = accounting.reconciliation
        try expect(lines.count >= 5)
        let kinds: Set<String> = Set(lines.map { String(describing: $0.kind) })
        try expect(kinds.count >= 3, "reconciliation should draw on several kinds of evidence")

        // The final line must always be the derived remainder.
        try expectEqual(lines.last?.kind, .derived)
    }
}
