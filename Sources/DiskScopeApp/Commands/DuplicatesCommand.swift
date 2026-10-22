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

/// `diskscope duplicates [path] [--min-size BYTES]`
///
/// Finds byte-identical duplicate files in the given path and reports how much
/// space could be reclaimed by removing the duplicates.
public struct DuplicatesCommand: Command {
    public let name = "duplicates"
    public let summary = "Find byte-identical duplicate files"

    public func run(options: Options, terminal: Terminal) async throws -> Int32 {
        let target = options.targetPath()

        guard FileManager.default.fileExists(atPath: target.path) else {
            terminal.line(terminal.paint("No such path: \(target.path)", .red))
            return 1
        }

        let defaultMinimumSize: Int64 = 1024 * 1024
        let minimumSize: Int64
        if let raw = options.value("min-size") {
            guard let parsed = ByteFormat.parse(raw) else {
                terminal.line(terminal.paint("Could not read --min-size \"\(raw)\". Use a number of bytes, like 1048576 or 5MB.", .red))
                return 1
            }
            minimumSize = parsed
        } else {
            minimumSize = defaultMinimumSize
        }

        let configuration = DuplicateFinderConfiguration(
            minimumSize: minimumSize,
            sampleSize: 64 * 1024,
            maxFilesToHash: 10_000
        )

        terminal.heading("Scanning for duplicates in \(terminal.bold(target.path))")
        terminal.line()

        // The scan records every file at or above the threshold, which is
        // exactly the set the finder needs. Recording them during the walk is
        // what keeps this to a single pass over the tree.
        let scanConfiguration = ScanConfiguration(
            roots: [target],
            largeFileThreshold: minimumSize,
            maximumLargeFiles: 200_000,
            skipGitInternals: true
        )

        let scan = try await FileSystemScanner(configuration: scanConfiguration).scanToCompletion()
        let result = await DuplicateFinder(configuration: configuration).findDuplicates(in: scan)

        render(result: result, minimumSize: minimumSize, terminal: terminal)
        return 0
    }

    private func render(
        result: DuplicateFinderResult,
        minimumSize: Int64,
        terminal: Terminal
    ) {
        terminal.line(terminal.dim("Examined \(ByteFormat.bare(result.filesConsidered)) files of \(ByteFormat.string(minimumSize)) and above."))
        terminal.line()

        if result.isEmpty {
            terminal.line("No duplicates found.")
            terminal.line()
        } else {
            terminal.heading("Duplicate files found")
            terminal.line()

            terminal.line("Total reclaimable space: \(terminal.bold(ByteFormat.string(result.totalWastedBytes)))")
            terminal.line()

            for (index, group) in result.groups.enumerated() {
                let copies = "\(group.memberCount) copies"
                terminal.line("\(index + 1). \(terminal.bold(group.primaryCopy?.displayName ?? "Unknown"))  \(terminal.dim(copies))")
                terminal.line("   Size per copy: \(ByteFormat.string(group.logicalSize))")
                terminal.line("   Reclaimable:   \(terminal.bold(ByteFormat.string(group.wastedBytes)))")
                terminal.line("   Keep:          \(group.primaryCopy?.url.path ?? "Unknown")")
                terminal.line("   SHA-256:       \(terminal.dim(String(group.contentDigest.prefix(16))))")

                for member in group.members where member.url != group.primaryCopy?.url {
                    let age = ByteFormat.relativeAge(member.modificationDate)
                    let hardLink = member.isHardLinked ? terminal.dim(" (hard link)") : ""
                    terminal.line("   Remove:        \(member.url.path) \(terminal.dim(age))\(hardLink)")
                }

                // Two names for one file are not two copies of it, and saying
                // otherwise would promise space that cannot be reclaimed.
                if group.distinctInodeCount < group.memberCount {
                    terminal.line()
                    terminal.line(terminal.dim("   \(group.memberCount) names for \(group.distinctInodeCount) file(s); hard-linked copies release no space."))
                }

                terminal.line()
            }
        }

        guard !result.caveats.isEmpty else { return }

        terminal.heading("Incomplete")
        terminal.line()
        for caveat in result.caveats {
            terminal.line("  \(terminal.paint(caveat.reason, .yellow))")
        }
        terminal.line()
    }
}
