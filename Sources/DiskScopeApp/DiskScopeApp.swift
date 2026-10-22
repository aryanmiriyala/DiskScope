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

/// Entry point for the `diskscope` command line tool.
@main
struct DiskScopeMain {
    static func main() async {
        // `ProcessInfo` rather than `CommandLine`: `CommandLine.arguments` is a
        // mutable static property, and older SDKs do not mark it safe, so the
        // Swift 6 concurrency checker refuses to read it from here. Both hand
        // back the same arguments.
        let options = Options(ProcessInfo.processInfo.arguments)
        let terminal = Terminal(forceColor: options.has("no-color") ? false : nil)

        let commands: [any Command] = [
            ExplainCommand(),
            DiskCommand(),
            DoctorCommand(),
            CategoriesCommand(),
            DuplicatesCommand(),
        ]
        let help = HelpCommand(commands: commands)

        let command: any Command
        switch options.command {
        case "help", "--help", "-h":
            command = help
        case "version", "--version":
            print("DiskScope \(Self.version)")
            exit(0)
        default:
            guard let match = commands.first(where: { $0.name == options.command }) else {
                terminal.line(terminal.paint("Unknown command: \(options.command)", .red))
                terminal.line()
                _ = try? await help.run(options: Options([]), terminal: terminal)
                exit(2)
            }
            command = match
        }

        do {
            let status = try await command.run(options: options, terminal: terminal)
            exit(status)
        } catch let error as ScanError {
            terminal.line(terminal.paint(error.errorDescription ?? "Scan failed.", .red))
            exit(1)
        } catch {
            terminal.line(terminal.paint("Something went wrong: \(error)", .red))
            exit(1)
        }
    }

    static let version = "0.1.0"
}
