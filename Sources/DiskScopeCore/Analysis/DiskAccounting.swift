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

/// Reconciles what DiskScope measured on disk against what macOS says the disk
/// is using.
///
/// This exists because of the thing that started this project. Finder reports a
/// single "used" figure for an APFS container; every folder you can actually
/// open adds up to less than that; and the remainder is labelled "System Data",
/// which is not a folder and cannot be inspected. On a modern Mac the container
/// is not even one filesystem — the read-only system volume and your data volume
/// share a single pool of blocks and are each given their own accounting.
///
/// The approach here is arithmetic, not storytelling. Take the number the
/// filesystem reports, subtract what was measured, and state the remainder
/// explicitly rather than assigning it to a plausible-sounding cause. Where a
/// cause *is* known and measurable it is attributed; where it is not, that is
/// said plainly.
public struct DiskAccounting: Sendable {

    /// One line in the reconciliation, with an optional measured quantity.
    public struct Line: Sendable, Identifiable {
        public enum Kind: Sendable {
            /// A figure taken directly from the filesystem.
            case measured
            /// A figure macOS reports, not measured by us.
            case reported
            /// Arithmetic on the above.
            case derived
            /// Something we know about but cannot put a number on.
            case known
        }

        public let text: String
        public let bytes: Int64?
        public let kind: Kind

        public var id: String { text }

        public init(text: String, bytes: Int64? = nil, kind: Kind) {
            self.text = text
            self.bytes = bytes
            self.kind = kind
        }
    }

    /// The volume whose figures we are reconciling.
    public let volume: VolumeUsage
    /// Physical bytes found by walking the filesystem.
    public let scannedBytes: Int64
    /// Space macOS says it can reclaim at will.
    public let purgeableBytes: Int64?
    /// How many local Time Machine snapshots exist.
    public let localSnapshotCount: Int
    /// Every other mounted volume, including ones sharing this pool.
    public let otherVolumes: [VolumeUsage]

    public init(
        volume: VolumeUsage,
        scannedBytes: Int64,
        purgeableBytes: Int64? = nil,
        localSnapshotCount: Int = 0,
        otherVolumes: [VolumeUsage] = []
    ) {
        self.volume = volume
        self.scannedBytes = scannedBytes
        self.purgeableBytes = purgeableBytes
        self.localSnapshotCount = localSnapshotCount
        self.otherVolumes = otherVolumes
    }

    /// Convenience build from a scan plus whatever the OS could tell us.
    public init(scan: ScanResult, purging purgeableBytes: Int64? = nil) {
        self.init(
            volume: VolumeProbe.dataVolume() ?? VolumeProbe.usage().first
                ?? VolumeUsage(volumeName: "unknown", mountPoint: "/", totalBytes: 0, freeBytes: 0, availableBytes: 0),
            scannedBytes: scan.scannedAllocatedSize,
            purgeableBytes: purgeableBytes,
            localSnapshotCount: VolumeProbe.localSnapshotBytes().count,
            otherVolumes: VolumeProbe.usage().filter { $0.mountPoint != "/" }
        )
    }

    /// What the filesystem reports as used.
    public var usedBytes: Int64 { volume.usedBytes }

    /// What our walk found.
    public var accountedBytes: Int64 { scannedBytes }

    /// Space the filesystem reports as used that no folder accounts for.
    public var unexplainedBytes: Int64 { max(0, usedBytes - scannedBytes) }

    /// Bytes we measured beyond what the volume can possibly hold.
    ///
    /// This is not a rounding error and it is not rare: on a real home directory
    /// the walk reported 318 GB against a 213 GB volume. Two things cause it,
    /// and neither is currently correctable here:
    ///
    /// * **APFS clones.** Copy-on-write means two paths can reference one set of
    ///   physical blocks while each reports the full size in `st_blocks`. Every
    ///   ordinary file-size tool counts both, which is why `du` over-reports on
    ///   macOS too and why tools like `dua` need a separate, slower pass to
    ///   deduplicate clones.
    /// * **Firm links.** `/usr`, `/bin` and `/System/Library` are firm links
    ///   into the sealed system volume. Walking `/` reaches system content
    ///   through a path that is not where it is stored.
    ///
    /// Reporting a total larger than the disk is a serious failure for a tool
    /// whose entire premise is trustworthy arithmetic, so it is stated plainly
    /// rather than clamped away.
    public var overCountedBytes: Int64 { max(0, scannedBytes - usedBytes) }

    /// True when the measurement exceeds the volume, which means the figure is
    /// not a clean account of anything.
    public var isOverCounting: Bool { overCountedBytes > 0 }

    /// The gap as a fraction of what is used, or nil when there is nothing to
    /// divide by.
    public func unexplainedFraction() -> Double? {
        guard usedBytes > 0 else { return nil }
        return Double(unexplainedBytes) / Double(usedBytes)
    }

    /// Whether the figures are close enough that the explanation is honest
    /// rather than hand-wavy.
    ///
    /// A small remainder is expected — directory inodes, APFS metadata, files
    /// deleted but not yet reclaimed. A large one means something real is
    /// unaccounted for and the report should say so rather than shrug.
    public func isReconciled(tolerance: Double = 0.02) -> Bool {
        guard let fraction = unexplainedFraction() else { return true }
        return fraction <= tolerance
    }

    /// The ordered explanation.
    ///
    /// Built so that each line is either a measured figure, a figure macOS
    /// reported, or arithmetic on those. No line asserts a cause we cannot
    /// support.
    public var reconciliation: [Line] {
        var lines: [Line] = []

        lines.append(Line(
            text: "macOS reports this volume as used",
            bytes: usedBytes,
            kind: .reported
        ))
        lines.append(Line(
            text: "DiskScope measured on disk",
            bytes: scannedBytes,
            kind: .measured
        ))

        // Purgeable is macOS's own figure and is space it holds but is willing to
        // release, so it legitimately sits between "used" and "yours".
        if let purgeable = purgeableBytes, purgeable > 0 {
            lines.append(Line(
                text: "of which macOS holds as purgeable and will release on demand",
                bytes: purgeable,
                kind: .reported
            ))
        }

        if localSnapshotCount > 0 {
            // Deliberately no number. Summing snapshot sizes means walking the
            // entire volume once per snapshot, which is far too slow to do
            // interactively, and estimating would be a guess. This is a real
            // limitation and is reported as one.
            lines.append(Line(
                text: "\(localSnapshotCount) local Time Machine snapshot\(localSnapshotCount == 1 ? "" : "s") exist. These are APFS snapshots rather than files, so no directory walk can measure them.",
                bytes: nil,
                kind: .known
            ))
        }

        // Volumes sharing the container hold blocks that this volume's own
        // accounting may or may not include.
        if !otherVolumes.isEmpty {
            let sharing = otherVolumes.filter { $0.totalBytes == volume.totalBytes }
            if !sharing.isEmpty {
                let names = sharing.map(\.volumeName).joined(separator: ", ")
                lines.append(Line(
                    text: "\(sharing.count) other volume\(sharing.count == 1 ? "" : "s") share this \(ByteFormat.string(volume.totalBytes)) pool with the volume being measured: \(names). Blocks used by one are charged to the container, not to any single folder.",
                    bytes: nil,
                    kind: .known
                ))
            }
        }

        if isOverCounting {
            lines.append(Line(
                text: "Measured more than the volume can hold. APFS clones and firm links each let one set of blocks be counted under more than one path, so folder sizes are not additive on macOS.",
                bytes: overCountedBytes,
                kind: .derived
            ))
        }

        lines.append(Line(
            text: unexplainedBytes > 0
                ? "Not accounted for by any folder"
                : (isOverCounting ? "Every used block is inside a folder, but folder sizes over-count" : "Measured folders account for all of it"),
            bytes: unexplainedBytes,
            kind: .derived
        ))

        return lines
    }

    /// A short verdict for the top of the report.
    public var verdict: String {
        guard usedBytes > 0 else {
            return "No volume figures were available."
        }
        if isOverCounting {
            return """
            DiskScope measured \(ByteFormat.string(overCountedBytes)) more than this volume \
            holds. That is not an error in the scan: on APFS, cloned files and firm \
            links let one set of blocks be counted under several paths, so folder \
            sizes do not add up to a disk total. Treat the categories below as \
            proportions, not as an account to reconcile.
            """
        }

        guard unexplainedBytes > 0 else {
            return "Every byte the filesystem reports as used is accounted for by a folder on disk."
        }
        let fraction = unexplainedFraction().map { _ in
            ByteFormat.percent(unexplainedBytes, of: usedBytes)
        } ?? "some"
        if isReconciled() {
            return """
            \(ByteFormat.string(unexplainedBytes)) (\(fraction)) is not attributable to a folder. \
            A remainder this small is normal: it is directory metadata and space \
            macOS has not reclaimed yet.
            """
        }
        return """
        \(ByteFormat.string(unexplainedBytes)) (\(fraction)) is not attributable to any folder \
        DiskScope walked. That is too large to be metadata. Local snapshots are the \
        most likely cause, and macOS offers no supported way to measure them without \
        walking the whole volume once per snapshot.
        """
    }
}
