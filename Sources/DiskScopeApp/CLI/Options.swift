import Foundation

/// A tiny flag parser.
///
/// Deliberately hand-rolled. This tool ships no third-party code, and a CLI
/// argument parser is not a large enough problem to justify a dependency that
/// would run alongside a filesystem walker holding Full Disk Access.
public struct Options {
    public var command: String = "help"
    public var positional: [String] = []
    public var flags: Set<String> = []
    public var values: [String: String] = [:]

    public init(_ arguments: [String]) {
        var iterator = arguments.makeIterator()
        _ = iterator.next()   // executable name

        var remaining: [String] = []
        for argument in iterator {
            if argument.hasPrefix("--") {
                let body = String(argument.dropFirst(2))
                if let equals = body.firstIndex(of: "=") {
                    values[String(body[body.startIndex..<equals])] = String(body[body.index(after: equals)...])
                } else {
                    flags.insert(body)
                }
            } else if argument.hasPrefix("-") && argument.count > 1 {
                flags.insert(String(argument.dropFirst()))
            } else {
                remaining.append(argument)
            }
        }

        if let first = remaining.first {
            command = first
            positional = Array(remaining.dropFirst())
        }
    }

    public func has(_ flag: String) -> Bool { flags.contains(flag) }

    public func value(_ key: String) -> String? { values[key] }

    /// Number of items to show, from `--limit N`.
    public var limit: Int? {
        guard let raw = values["limit"] ?? values["n"], let parsed = Int(raw), parsed > 0 else {
            return nil
        }
        return parsed
    }

    /// The path to operate on, defaulting to the home directory.
    ///
    /// The path arrives as a positional argument (`diskscope explain ~/Downloads`),
    /// so it is read from `positional` and not from a dedicated property. An
    /// earlier version looked for a `path` property that was never assigned,
    /// which meant every invocation silently scanned the entire home directory
    /// instead of what was asked for.
    public func targetPath(fileSystem: FileManager = .default) -> URL {
        let raw = positional.first ?? values["path"] ?? fileSystem.homeDirectoryForCurrentUser.path
        let expanded = (raw as NSString).expandingTildeInPath
        return URL(fileURLWithPath: (expanded as NSString).standardizingPath)
    }

    /// Where JSON output goes, if requested.
    public var jsonPath: String? { values["json"] }
}
