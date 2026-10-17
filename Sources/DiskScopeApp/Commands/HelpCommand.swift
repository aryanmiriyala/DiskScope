import Foundation
import DiskScopeCore

/// `diskscope help [command]`
public struct HelpCommand: Command {
    public let name = "help"
    public let summary = "Show usage"

    private let commands: [any Command]

    public init(commands: [any Command]) {
        self.commands = commands
    }

    public func run(options: Options, terminal: Terminal) async throws -> Int32 {
        // `diskscope help explain` shows one command in detail.
        if let topic = options.positional.first,
           let command = commands.first(where: { $0.name == topic }) {
            terminal.heading("diskscope \(command.name)")
            terminal.line()
            terminal.line("  \(command.summary)")
            if !command.discussion.isEmpty {
                terminal.line()
                for line in terminal.wrap(command.discussion, to: max(30, terminal.width - 4)) {
                    terminal.line("  \(line)")
                }
            }
            terminal.line()
            return 0
        }

        terminal.heading("DiskScope")
        terminal.line()
        terminal.line("  \(terminal.dim("Understand where your Mac's disk space actually went."))")
        terminal.line()

        let nameWidth = commands.map(\.name.count).max() ?? 10
        for command in commands {
            let name = terminal.pad(command.name, to: nameWidth)
            terminal.line("  \(terminal.bold(name))  \(command.summary)")
        }

        terminal.line()
        terminal.line("  \(terminal.dim("Run \(terminal.bold("diskscope help <command>")) for detail."))")
        terminal.line()
        terminal.line("  \(terminal.dim("Common flags:  --limit N    --json FILE    --no-color"))")
        terminal.line()
        return 0
    }
}
