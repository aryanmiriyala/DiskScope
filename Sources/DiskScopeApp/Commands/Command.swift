import Foundation
import DiskScopeCore

/// A subcommand of the `diskscope` binary.
public protocol Command: Sendable {
    var name: String { get }
    var summary: String { get }
    /// One or two lines of detail, shown by `diskscope help <name>`.
    var discussion: String { get }
    func run(options: Options, terminal: Terminal) async throws -> Int32
}

public extension Command {
    var discussion: String { "" }
}
