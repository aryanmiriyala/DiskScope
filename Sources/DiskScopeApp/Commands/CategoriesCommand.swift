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
