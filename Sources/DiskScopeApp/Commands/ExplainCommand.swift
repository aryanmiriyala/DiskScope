import Foundation
import DiskScopeCore

/// `diskscope explain [path]`
///
/// The primary command. Scans a location, groups what it finds into explained
/// categories, and says what each one is and whether removing it is safe.
public struct ExplainCommand: Command {
    public let name = "explain"
    public let summary = "Scan a location and explain what is using the space"

    public func run(options: Options, terminal: Terminal) async throws -> Int32 {
        let target = options.targetPath()

        guard FileManager.default.fileExists(atPath: target.path) else {
            terminal.line(terminal.paint("No such path: \(target.path)", .red))
            terminal.line(terminal.dim("Check the path and try again."))
            return 1
        }

        if let jsonPath = options.jsonPath {
            return try await runJSON(target: target, jsonPath: jsonPath, terminal: terminal)
        }

        let configuration = ScanConfiguration(
            roots: [target],
            largeFileThreshold: 200 * 1024 * 1024,
            skipGitInternals: true
        )

        terminal.heading("Scanning \(terminal.bold(target.path))")
        terminal.line()

        let scan = try await runScan(configuration: configuration, terminal: terminal)
        let report = BreakdownReport(scan: scan)

        render(report: report, scan: scan, terminal: terminal, limit: options.limit)
        return 0
    }

    // MARK: - Rendering

    private func render(
        report: BreakdownReport,
        scan: ScanResult,
        terminal: Terminal,
        limit: Int?
    ) {
        let totals = Array(report.categoryTotals.prefix(limit ?? 12))

        terminal.heading("What is using the space")

        // Size, name, explanation. The explanation is the product; the size
        // column just tells you which one to read.
        let sizeColumn = 11
        let nameColumn = 24

        for total in totals {
            let size = terminal.pad(ByteFormat.string(total.allocatedSize), to: sizeColumn, align: .right)
            let name = terminal.pad(terminal.truncate(total.category.title, to: nameColumn), to: nameColumn)
            let indent = String(repeating: " ", count: sizeColumn + 3)

            let explanation = total.category.explanation
                .replacingOccurrences(of: "\n", with: " ")
                .split(separator: " ", omittingEmptySubsequences: true)
                .joined(separator: " ")

            let available = max(24, terminal.width - sizeColumn - nameColumn - 5)
            let wrapped = terminal.wrap(explanation, to: available)

            terminal.line("  \(terminal.paint(size, .bold))  \(terminal.bold(name))  \(wrapped.first ?? "")")
            for continuation in wrapped.dropFirst() {
                terminal.line("\(indent)\(continuation)")
            }

            if let note = total.category.originNote {
                terminal.line("\(indent)\(terminal.dim(note))")
            }
            terminal.line()
        }

        renderTotals(report: report, scan: scan, terminal: terminal)
        renderCoverage(scan: scan, terminal: terminal)
        renderFirstStep(report: report, terminal: terminal)
    }

    private func renderTotals(report: BreakdownReport, scan: ScanResult, terminal: Terminal) {
        terminal.heading("Totals")

        terminal.line("  \(terminal.dim("Measured"))              \(terminal.bold(ByteFormat.string(report.totalAllocatedBytes)))")
        terminal.line("  \(terminal.dim("Safe to clear"))         \(terminal.paint(ByteFormat.string(report.reclaimableBytes), .green))")

        // `scan.fileCount` sums the per-directory counts, not the subtree
        // totals, so nothing is counted twice.
        let files = scan.fileCount
        let directories = scan.totalDirectoryCount
        terminal.line("  \(terminal.dim("Contents"))              \(ByteFormat.bare(files)) files in \(ByteFormat.bare(directories)) directories")

        if scan.deduplicatedHardLinks > 0 {
            terminal.line("  \(terminal.dim("Hard links"))            \(ByteFormat.bare(scan.deduplicatedHardLinks)) counted once")
        }

        if let volume = scan.volumeTotals.first(where: { $0.mountPoint == "/" })
            ?? scan.volumeTotals.first {
            let nearlyFull = volume.usedBytes > volume.totalBytes * 9 / 10
            terminal.line("  \(terminal.dim("Disk free"))           \(ByteFormat.string(volume.availableBytes)) of \(ByteFormat.string(volume.totalBytes))")
            terminal.line("  \(terminal.dim("Disk used"))           \(terminal.paint(ByteFormat.string(volume.usedBytes), nearlyFull ? .red : .reset))")
        }
        terminal.line()
    }

    private func renderCoverage(scan: ScanResult, terminal: Terminal) {
        guard !scan.deniedPaths.isEmpty else { return }

        let permissionDenials = scan.deniedPaths.filter { $0.reason == .permissionDenied }
        let otherDenials = scan.deniedPaths.filter { $0.reason != .permissionDenied }

        terminal.heading("Incomplete")

        if permissionDenials.isEmpty {
            // Nothing was blocked by macOS, so the totals are complete for
            // permission purposes. Other denials still need reporting, but must
            // not be described as missing permissions — an earlier version
            // printed "0 directories could not be read" here, which read as an
            // accusation that the scan was incomplete when it was not.
            terminal.line("  Every readable location was read successfully.")
            if !otherDenials.isEmpty {
                terminal.line()
                terminal.line("  \(otherDenials.count) entries changed or failed while scanning:")
                for denial in otherDenials.prefix(3) {
                    terminal.line("    \(terminal.dim(denial.url.path))")
                    terminal.line("    \(terminal.dim(denial.reason.explanation))")
                }
            }
        } else {
            terminal.line("  \(terminal.paint("\(permissionDenials.count) locations could not be read", .yellow)), so these")
            terminal.line("  totals are lower than the real figure.")

            // Show the top few, because "your numbers are wrong" is much easier
            // to act on with a path attached.
            for denial in permissionDenials.prefix(5) {
                terminal.line("    \(terminal.dim(denial.url.path))")
            }
            if permissionDenials.count > 5 {
                terminal.line("    \(terminal.dim("and \(permissionDenials.count - 5) more"))")
            }

            terminal.line()
            terminal.line("  \(terminal.dim("macOS hides these until Full Disk Access is granted."))")
            terminal.line("  \(terminal.dim("Run \(terminal.bold("diskscope doctor")) to check."))")
        }
        terminal.line()
    }

    private func renderFirstStep(report: BreakdownReport, terminal: Terminal) {
        guard let step = report.bestFirstStep else {
            if report.unexplainedBytes > 0 {
                terminal.line(terminal.dim("  Nothing is flagged as safe to clear automatically."))
                terminal.line()
            }
            return
        }

        terminal.heading("Start here")

        terminal.line("  \(terminal.bold(step.category.title))  \(terminal.bold(ByteFormat.string(step.reclaimableSize)))")
        terminal.line("  \(terminal.paint(risk: step.risk)) — \(step.risk.summary)")
        terminal.line()
        terminal.line("  \(terminal.dim("Cleanup is not implemented yet. Nothing has been changed."))")
        terminal.line()
    }

    // MARK: - Scanning

    /// Run the scan, showing live progress when the terminal can display it.
    private func runScan(configuration: ScanConfiguration, terminal: Terminal) async throws -> ScanResult {
        var result: ScanResult?

        for try await update in FileSystemScanner(configuration: configuration).scan() {
            switch update {
            case .progress(let progress):
                renderProgress(progress, terminal: terminal)
            case .finished(let scanResult):
                result = scanResult
            }
        }

        if terminal.isInteractive {
            terminal.raw("\r\u{1B}[2K")
        }

        guard let result else {
            throw ScanError.noRootsScanned
        }
        return result
    }

    private func renderProgress(_ progress: ScanProgress, terminal: Terminal) {
        guard terminal.isInteractive else { return }

        let message = "  \(terminal.dim("scanned")) \(ByteFormat.bare(progress.directoriesVisited)) dirs, "
            + "\(ByteFormat.bare(progress.filesSeen)) files, \(ByteFormat.string(progress.bytesSeen))"

        // Overwrite the previous line rather than scrolling.
        terminal.raw("\r\u{1B}[2K" + message)
    }

    // MARK: - JSON

    private func runJSON(target: URL, jsonPath: String, terminal: Terminal) async throws -> Int32 {
        let scan = try await FileSystemScanner(configuration: ScanConfiguration(roots: [target]))
            .scanToCompletion()
        let report = BreakdownReport(scan: scan)

        struct CategoryOutput: Codable {
            let category: String
            let title: String
            let bytes: Int64
            let logicalBytes: Int64
            let items: Int
            let risk: String
            let reclaimable: Bool
            let explanation: String
        }

        struct Output: Codable {
            let path: String
            let scannedBytes: Int64
            let reclaimableBytes: Int64
            let unreadablePaths: [String]
            let deduplicatedHardLinks: Int
            let categories: [CategoryOutput]
        }

        let output = Output(
            path: target.path,
            scannedBytes: report.totalAllocatedBytes,
            reclaimableBytes: report.reclaimableBytes,
            unreadablePaths: scan.deniedPaths.map(\.url.path),
            deduplicatedHardLinks: scan.deduplicatedHardLinks,
            categories: report.categoryTotals.map {
                CategoryOutput(
                    category: $0.category.rawValue,
                    title: $0.category.title,
                    bytes: $0.allocatedSize,
                    logicalBytes: $0.logicalSize,
                    items: $0.itemCount,
                    risk: $0.risk.rawValue.description,
                    reclaimable: $0.reclaimableSize > 0,
                    explanation: $0.category.explanation
                )
            }
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(output)

        if jsonPath == "-" {
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
        } else {
            try data.write(to: URL(fileURLWithPath: (jsonPath as NSString).expandingTildeInPath))
            terminal.line("Wrote \(terminal.bold(jsonPath))")
        }
        return 0
    }
}
