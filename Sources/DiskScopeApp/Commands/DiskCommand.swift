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

/// `diskscope disk`
///
/// The whole-disk report, and the command that answers the question this tool
/// exists for: *macOS says 168 GB is used, my folders add up to 90 GB, where
/// did the rest go?*
///
/// It walks the boot volume, breaks it down into explained categories, and then
/// reconciles its own measured total against the figure the filesystem reports.
/// Where the remainder cannot be attributed to a folder, that is stated rather
/// than explained away.
public struct DiskCommand: Command {
    public let name = "disk"
    public let summary = "Explain the whole boot volume and reconcile the numbers"

    public let discussion = """
    Scans the boot volume, shows the breakdown by category, then accounts for \
    the difference between what macOS reports as used and what DiskScope \
    actually measured. Any remainder is stated explicitly instead of being \
    assigned a convenient cause.
    """

    public func run(options: Options, terminal: Terminal) async throws -> Int32 {
        let target = URL(fileURLWithPath: "/")

        terminal.heading("Analysing the boot volume")
        terminal.line()

        let configuration = ScanConfiguration(
            roots: [target],
            largeFileThreshold: 500 * 1024 * 1024,
            skipGitInternals: true
        )

        var scan: ScanResult?
        for try await update in FileSystemScanner(configuration: configuration).scan() {
            switch update {
            case .progress(let progress):
                if terminal.isInteractive {
                    let message = "  \(terminal.dim("scanned")) \(ByteFormat.bare(progress.directoriesVisited)) dirs, "
                        + "\(ByteFormat.bare(progress.filesSeen)) files, \(ByteFormat.string(progress.bytesSeen))"
                    terminal.raw("\r\u{1B}[2K" + message)
                }
            case .finished(let result):
                scan = result
            }
        }
        if terminal.isInteractive { terminal.raw("\r\u{1B}[2K") }

        guard let scan else { throw ScanError.noRootsScanned }

        let report = BreakdownReport(scan: scan)
        let accounting = DiskAccounting(
            scan: scan,
            purging: VolumeProbe.purgeableBytes(at: target)
        )

        renderCategories(report: report, terminal: terminal, limit: options.limit ?? 16)
        renderContainer(accounting: accounting, terminal: terminal)
        renderReconciliation(accounting: accounting, scan: scan, terminal: terminal)
        renderIncomplete(scan: scan, terminal: terminal)

        return 0
    }

    // MARK: - Sections

    private func renderCategories(report: BreakdownReport, terminal: Terminal, limit: Int) {
        terminal.heading("What is using the space")
        let totals = Array(report.categoryTotals.prefix(limit))
        let largest = totals.first?.allocatedSize ?? 1
        let barWidth = 18

        for total in totals {
            let size = terminal.pad(ByteFormat.string(total.allocatedSize), to: 10, align: .right)
            let name = terminal.pad(terminal.truncate(total.category.title, to: 26), to: 26)
            let filled = max(1, Int((Double(total.allocatedSize) / Double(largest)) * Double(barWidth)))
            let bar = String(repeating: "\u{2588}", count: filled)
            let coloured = total.risk.isDeletable ? terminal.paint(bar, .blue) : terminal.dim(bar)

            terminal.line("  \(terminal.paint(size, .bold))  \(terminal.bold(name))  \(coloured)")
        }
        terminal.line()
    }

    private func renderContainer(accounting: DiskAccounting, terminal: Terminal) {
        let volume = accounting.volume
        terminal.heading("The container")
        terminal.line()
        terminal.line("  \(terminal.dim("Total"))     \(ByteFormat.string(volume.totalBytes))")
        terminal.line("  \(terminal.dim("Used"))      \(terminal.bold(ByteFormat.string(accounting.usedBytes)))")
        terminal.line("  \(terminal.dim("Free"))      \(ByteFormat.string(volume.freeBytes))")
        terminal.line("  \(terminal.dim("Available")) \(ByteFormat.string(volume.availableBytes))   \(terminal.dim("(what you can actually write)"))")

        if volume.totalBytes > 0 {
            let used = Double(volume.usedBytes)
            let total = Double(volume.totalBytes)
            let filled = Int((used / total) * 40)
            let bar = String(repeating: "\u{2588}", count: max(0, min(40, filled)))
            let colour: Terminal.Style = volume.usedBytes > volume.totalBytes * 9 / 10 ? .red : .blue
            terminal.line()
            terminal.line("  \(terminal.paint(bar, colour)) \(terminal.dim(ByteFormat.percent(volume.usedBytes, of: volume.totalBytes)))")
        }
        terminal.line()
    }

    /// The heart of the command: what the filesystem reports versus what we
    /// measured, with every figure labelled by where it came from.
    private func renderReconciliation(
        accounting: DiskAccounting,
        scan: ScanResult,
        terminal: Terminal
    ) {
        terminal.heading("Where the numbers differ")
        terminal.line()

        for line in accounting.reconciliation {
            let marker: String
            let colour: Terminal.Style
            switch line.kind {
            case .measured: marker = "\u{25CF}"; colour = .green
            case .reported: marker = "\u{25CB}"; colour = .yellow
            case .derived:  marker = "="; colour = .blue
            case .known:    marker = "\u{00B7}"; colour = .grey
            }

            let value = line.bytes.map { terminal.pad(ByteFormat.string($0), to: 10, align: .right) }
                ?? terminal.pad("", to: 10)
            terminal.line("  \(terminal.paint(marker, colour)) \(value)  \(line.text)")
        }

        terminal.line()
        terminal.line("  \(terminal.dim("\u{25CF} measured by DiskScope    \u{25CB} reported by macOS    = arithmetic    \u{00B7} known, not measurable"))")
        terminal.line()
        terminal.line("  \(accounting.verdict)")
        terminal.line()
    }

    private func renderIncomplete(scan: ScanResult, terminal: Terminal) {
        guard !scan.deniedPaths.isEmpty || !scan.skippedMounts.isEmpty else { return }

        terminal.heading("Not included above")
        terminal.line()

        let denials = scan.deniedPaths.filter { $0.reason == .permissionDenied }
        if !denials.isEmpty {
            terminal.line("  \(terminal.paint("\(denials.count) locations", .yellow)) could not be read without Full Disk Access:")
            for denial in denials.prefix(4) {
                terminal.line("    \(terminal.dim(denial.url.path))")
            }
        }

        if !scan.skippedMounts.isEmpty {
            terminal.line()
            terminal.line("  \(terminal.paint("\(scan.skippedMounts.count) mounted volume\(scan.skippedMounts.count == 1 ? "" : "s")", .grey)) left unwalked, because they sit on a different filesystem:")
            for mount in scan.skippedMounts.prefix(6) {
                terminal.line("    \(terminal.dim(mount.url.path))")
            }
            terminal.line("    \(terminal.dim("Run against one directly to include it."))")
        }
        terminal.line()
    }
}
