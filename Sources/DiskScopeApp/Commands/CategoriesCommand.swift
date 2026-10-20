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

/// `diskscope categories`
///
/// Prints the whole taxonomy, in plain text.
///
/// The category explanations are the product. A user who wants to know what
/// DiskScope thinks about a folder should be able to read every category it
/// knows about without running a scan first, and contributors adding rules
/// need the same list to see what is already covered.
public struct CategoriesCommand: Command {
    public let name = "categories"
    public let summary = "List every category DiskScope recognises and what it means"

    public func run(options: Options, terminal: Terminal) async throws -> Int32 {
        terminal.heading("Categories")
        terminal.line()

        for category in DiskCategory.allCases {
            let title = terminal.pad(terminal.truncate(category.title, to: 28), to: 28)
            let risk = terminal.pad(terminal.paint(risk: category.defaultRisk), to: 16)

            terminal.line("  \(terminal.bold(title)) \(risk)")
            for line in terminal.wrap(flatten(category.explanation), to: max(30, terminal.width - 8)) {
                terminal.line("      \(terminal.dim(line))")
            }
            if let note = category.originNote {
                terminal.line("      \(terminal.dim("↳ " + note))")
            }
            terminal.line()
        }

        return 0
    }

    /// Collapse the multi-line explanations into one paragraph.
    private func flatten(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\n", with: " ")
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
    }
}
