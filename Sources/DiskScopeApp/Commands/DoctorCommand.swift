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

/// `diskscope doctor`
///
/// Answers one question: can this process actually read what it needs to?
///
/// A disk analyser that quietly reports zero for every directory it was denied
/// access to is indistinguishable from one that found nothing. This command
/// probes the locations that actually need Full Disk Access on macOS and prints
/// what worked, so a permission problem is visible instead of inferred from a
/// disappointing number.
public struct DoctorCommand: Command {
    public let name = "doctor"
    public let summary = "Check whether macOS lets this tool read what it needs"

    public let discussion = """
    Probes the locations on macOS that are protected by default, and reports \
    exactly which ones are readable. If something comes back as denied, run \
    this again after granting Full Disk Access in System Settings › Privacy & \
    Security › Full Disk Access.
    """

    /// A location worth probing, and why.
    private struct Probe: Sendable {
        let url: URL
        let label: String
        let requiresFullDiskAccess: Bool
        /// True when macOS protects this from a plain terminal regardless of
        /// Full Disk Access, which would be misleading to report as a failure.
        let protectedByTCC: Bool
    }

    public func run(options: Options, terminal: Terminal) async throws -> Int32 {
        let probes = Self.probes()

        terminal.heading("Full Disk Access check")
        terminal.line()
        terminal.line("  Reading these locations requires granting Full Disk Access to")
        terminal.line("  the terminal or app running this command.")
        terminal.line()

        var failures: [Probe] = []
        var tccBlocked: [Probe] = []

        for probe in probes {
            let readable = FileManager.default.isReadableFile(atPath: probe.url.path)
            let exists = FileManager.default.fileExists(atPath: probe.url.path)

            let status: String
            let colour: Terminal.Style

            if !exists {
                status = "not present"
                colour = .grey
            } else if readable {
                status = "readable"
                colour = .green
            } else if probe.protectedByTCC {
                // Mail and Messages are gated even for a healthy terminal when
                // Full Disk Access has not been granted. Saying "denied" here
                // is accurate; saying "broken" would not be.
                status = "denied — needs Full Disk Access"
                colour = .yellow
                tccBlocked.append(probe)
            } else {
                status = "denied"
                colour = .red
                failures.append(probe)
            }

            let label = terminal.pad(terminal.truncate(probe.label, to: 34), to: 34)
            terminal.line("  \(terminal.paint(status, colour))  \(terminal.dim(label))")
            terminal.line("    \(terminal.dim(probe.url.path))")
        }

        terminal.line()

        if !failures.isEmpty {
            terminal.line(terminal.paint("  \(failures.count) location(s) could not be read.", .red))
            terminal.line()
            terminal.line("  Grant access in System Settings › Privacy & Security ›")
            terminal.line("  Full Disk Access, adding the program you ran this from")
            terminal.line("  (\(terminal.bold(terminalProgramName()))), then run this again.")
            terminal.line()
            return 1
        }

        if !tccBlocked.isEmpty {
            terminal.line(terminal.paint("  Some locations are still protected.", .yellow))
            terminal.line()
            terminal.line("  macOS hides these from every program until Full Disk Access is")
            terminal.line("  granted, including a normal Terminal session. Until then, any")
            terminal.line("  DiskScope report will undercount by whatever they contain.")
            terminal.line()
            return 0
        }

        terminal.line(terminal.paint("  Everything readable.", .green))
        terminal.line()
        return 0
    }

    /// The path the user should add to Full Disk Access.
    ///
    /// When run from a terminal this is the shell, not the DiskScope binary,
    /// because that is the process macOS actually attributes the permission to.
    private func terminalProgramName() -> String {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        return URL(fileURLWithPath: shell).lastPathComponent
    }

    private static func probes() -> [Probe] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let library = home.appending(path: "Library")

        return [
            Probe(
                url: library.appending(path: "Caches"),
                label: "Application caches",
                requiresFullDiskAccess: false,
                protectedByTCC: false
            ),
            Probe(
                url: library.appending(path: "Preferences"),
                label: "App preferences",
                requiresFullDiskAccess: false,
                protectedByTCC: false
            ),
            Probe(
                url: library.appending(path: "Application Support"),
                label: "Application support files",
                requiresFullDiskAccess: false,
                protectedByTCC: false
            ),
            Probe(
                url: library.appending(path: "Mail"),
                label: "Mail",
                requiresFullDiskAccess: true,
                protectedByTCC: true
            ),
            Probe(
                url: library.appending(path: "Messages"),
                label: "Messages",
                requiresFullDiskAccess: true,
                protectedByTCC: true
            ),
            Probe(
                url: library.appending(path: "Containers/com.apple.Safari"),
                label: "Safari data",
                requiresFullDiskAccess: true,
                protectedByTCC: true
            ),
            Probe(
                url: library.appending(path: "Mobile Documents"),
                label: "iCloud Drive",
                requiresFullDiskAccess: true,
                protectedByTCC: true
            ),
            Probe(
                url: library.appending(path: "Developer"),
                label: "Xcode and developer tools",
                requiresFullDiskAccess: false,
                protectedByTCC: false
            ),
            Probe(
                url: URL(fileURLWithPath: "/Library/Application Support"),
                label: "Shared application support",
                requiresFullDiskAccess: false,
                protectedByTCC: false
            ),
        ]
    }
}
