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

/// A compact, bounded projection of a scan that a language model is allowed to see.
///
/// This type is the security boundary for the AI features. Two rules are
/// enforced structurally rather than by convention:
///
/// 1. **Every value in here was measured.** Sizes come from `st_blocks`, paths
///    came from `readdir`, dates came from `stat`. A `ScanDigest` can only be
///    built from a `ScanResult`, so there is no way to hand a model a number
///    that DiskScope did not itself observe.
/// 2. **It is truncated, and says so.** A home directory can hold hundreds of
///    thousands of directories, which is far past any context window. We keep
///    the largest ones — the only ones worth explaining — and record how many
///    were dropped in `truncatedCount`. The model is told about the truncation
///    explicitly so it cannot present a partial view as a complete one.
///
/// The consequence is that the model never sees a total it could misattribute:
/// it sees a ranked list plus an explicit "N more not shown".
public struct ScanDigest: Sendable {
    /// One measured directory, flattened for a model to read.
    public struct Entry: Sendable, Codable, Identifiable {
        public let path: String
        /// Physical bytes. The authoritative figure.
        public let allocatedBytes: Int64
        public let fileCount: Int
        public let newestModification: Date?

        public var id: String { path }

        public init(path: String, allocatedBytes: Int64, fileCount: Int, newestModification: Date?) {
            self.path = path
            self.allocatedBytes = allocatedBytes
            self.fileCount = fileCount
            self.newestModification = newestModification
        }
    }

    public let entries: [Entry]
    /// How many directories existed but were not included, for budget reasons.
    public let truncatedCount: Int
    /// Physical bytes across everything that was scanned, including the
    /// truncated remainder. Included so the model can describe overall scale.
    public let totalAllocatedBytes: Int64
    public let generatedAt: Date
    /// Paths the scanner could not read, so the model can account for gaps.
    public let unreadablePathCount: Int

    private let knownPaths: Set<String>

    public init(
        entries: [Entry],
        truncatedCount: Int,
        totalAllocatedBytes: Int64,
        generatedAt: Date,
        unreadablePathCount: Int
    ) {
        self.entries = entries
        self.truncatedCount = truncatedCount
        self.totalAllocatedBytes = totalAllocatedBytes
        self.generatedAt = generatedAt
        self.unreadablePathCount = unreadablePathCount
        self.knownPaths = Set(entries.map(\.path))
    }

    /// Build a digest from a completed scan.
    ///
    /// `maximumEntries` bounds what reaches the model. The default of 400 is
    /// roughly the point where a path-and-size listing stops being useful to
    /// read and starts being noise.
    public init(from scan: ScanResult, maximumEntries: Int = 400) {
        // Rank by physical size: the largest directories are the ones a user
        // asking "what is going on" actually wants explained.
        let ranked = scan.directories
            .sorted { $0.subtreeAllocatedSize > $1.subtreeAllocatedSize }

        let kept = Array(ranked.prefix(max(maximumEntries, 0)))
        self.entries = kept.map { record in
            Entry(
                path: record.url.path,
                allocatedBytes: record.subtreeAllocatedSize,
                fileCount: record.fileCount,
                newestModification: record.newestModification
            )
        }
        self.truncatedCount = max(0, ranked.count - kept.count)
        self.totalAllocatedBytes = scan.scannedAllocatedSize
        self.generatedAt = scan.finishedAt
        self.unreadablePathCount = scan.deniedPaths.count
        self.knownPaths = Set(self.entries.map(\.path))
    }

    /// Whether `path` was actually observed during the scan.
    ///
    /// Every path a model cites is checked against this. A path that is not
    /// here did not come from the filesystem, and the response is rejected.
    public func contains(path: String) -> Bool {
        knownPaths.contains(path)
    }

    public func entry(for path: String) -> Entry? {
        entries.first { $0.path == path }
    }

    /// Sum of the measured sizes of `paths`, or nil if any are unknown.
    ///
    /// This is how the app gets a number back out of a model answer. The model
    /// contributes the *selection* of paths; the arithmetic is always ours.
    public func totalAllocated(for paths: [String]) -> Int64? {
        var total: Int64 = 0
        for path in paths {
            guard let entry = entry(for: path) else { return nil }
            total &+= entry.allocatedBytes
        }
        return total
    }

    /// Human-readable rendering handed to the model.
    ///
    /// Intentionally plain text with no decoration. Models parse this shape
    /// reliably, and a stable format keeps prompts diffable and testable.
    public func compactSummary() -> String {
        var lines: [String] = []
        lines.append("Directories measured: \(entries.count) (largest first)")
        lines.append("Total physical size across scan: \(ByteFormat.string(totalAllocatedBytes))")
        if truncatedCount > 0 {
            lines.append("NOTE: \(truncatedCount) smaller directories were omitted for length.")
        }
        if unreadablePathCount > 0 {
            lines.append("NOTE: \(unreadablePathCount) paths were unreadable and are absent from this list.")
        }
        lines.append("")
        lines.append("path\tbytes\tfiles\tlast_modified")

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]

        for entry in entries {
            let date = entry.newestModification.map(formatter.string(from:)) ?? "-"
            lines.append("\(entry.path)\t\(entry.allocatedBytes)\t\(entry.fileCount)\t\(date)")
        }
        return lines.joined(separator: "\n")
    }
}
