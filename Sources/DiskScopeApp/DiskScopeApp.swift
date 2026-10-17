import Foundation
import DiskScopeCore

/// Entry point for the `diskscope` command line tool.
@main
struct DiskScopeMain {
    static func main() async {
        let options = Options(CommandLine.arguments)
        let terminal = Terminal(forceColor: options.has("no-color") ? false : nil)

        let commands: [any Command] = [
            ExplainCommand(),
            DoctorCommand(),
            CategoriesCommand(),
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
