import Foundation

/// Turns a filesystem path into a `DiskCategory` plus a human explanation.
///
/// This is the part of DiskScope that actually answers "what is this?". The
/// rules live in one ordered table so the behaviour is inspectable and
/// testable rather than scattered through the UI.
///
/// Ordering matters. Rules are evaluated top to bottom and the first match
/// wins, so specific paths (`~/Library/Caches/com.apple.dt.Xcode`) are listed
/// before broad ones (`~/Library/Caches`).
public struct LibraryClassifier: Sendable {
    public enum Match: Sendable {
        /// A path prefix, compared against the standardized path.
        case prefix(String)
        /// An exact path.
        case exact(String)
        /// A component anywhere in the path.
        case component(String)
        /// The final path component equals one of these names.
        case fileName(String)
        /// The final path component matches this glob, `*` only.
        case suffix(String)
    }

    public struct Rule: Sendable {
        public let match: Match
        public let category: DiskCategory
        /// Overrides the category's default risk when this path is unusual
        /// enough that the general answer would be wrong.
        public let riskOverride: RiskLevel?

        public init(_ match: Match, _ category: DiskCategory, risk: RiskLevel? = nil) {
            self.match = match
            self.category = category
            self.riskOverride = risk
        }

        func matches(_ path: String, components: [String], lastComponent: String) -> Bool {
            switch match {
            case .prefix(let prefix):
                return path == prefix || path.hasPrefix(prefix + "/")
            case .exact(let exact):
                return path == exact
            case .component(let component):
                return components.contains(component)
            case .fileName(let name):
                return lastComponent == name
            case .suffix(let glob):
                return Self.glob(glob, matches: lastComponent)
            }
        }

        /// Single-star glob, which is all these rules need.
        public static func glob(_ pattern: String, matches candidate: String) -> Bool {
            guard let star = pattern.firstIndex(of: "*") else {
                return pattern == candidate
            }
            let prefix = String(pattern[pattern.startIndex..<star])
            let suffix = String(pattern[pattern.index(after: star)...])
            guard candidate.hasPrefix(prefix), candidate.hasSuffix(suffix) else { return false }
            return candidate.count >= prefix.count + suffix.count
        }
    }

    public let homeDirectory: URL
    public let rules: [Rule]

    public init(homeDirectory: URL = .homeDirectory) {
        self.homeDirectory = homeDirectory

        let home = homeDirectory.path
        let library = home + "/Library"

        // Ordered most-specific first. Read this top to bottom to understand
        // what DiskScope believes and why.
        self.rules = [
            // --- Developer tooling: the usual reason ~/Library gets huge ---
            // Prefix rules, not exact ones: Xcode nests a folder per project
            // beneath DerivedData and per build beneath Archives.
            Rule(.prefix(library + "/Developer/Xcode/DerivedData"), .developerCaches),
            Rule(.prefix(library + "/Developer/Xcode/Archives"), .xcodeArchives),
            Rule(.exact(library + "/Developer/Xcode/iOS DeviceSupport"), .developerCaches, risk: .disposable),
            Rule(.exact(library + "/Developer/Xcode/watchOS DeviceSupport"), .developerCaches, risk: .disposable),
            // Each simulator device is its own directory beneath Devices, so
            // this has to be a prefix to match a real path.
            Rule(.prefix(library + "/Developer/CoreSimulator/Devices"), .simulatorData, risk: .destructive),
            Rule(.exact(library + "/Developer/CoreSimulator/Caches"), .simulatorData, risk: .regenerable),
            Rule(.prefix(library + "/Developer/Xcode/UserData/Previews"), .developerCaches),
            Rule(.prefix(library + "/Developer"), .developerCaches, risk: .caution),

            // --- Device and simulator backups ---
            Rule(.exact(library + "/Application Support/MobileSync/Backup"), .iosDeviceBackups),
            Rule(.prefix(home + "/Library/Application Support/MobileSync"), .iosDeviceBackups),

            // --- Package managers ---
            Rule(.prefix(home + "/.cargo/registry"), .packageManagerCaches),
            Rule(.prefix(home + "/.npm"), .packageManagerCaches),
            Rule(.prefix(home + "/.cache/CocoaPods"), .packageManagerCaches),
            Rule(.prefix(home + "/.cocoapods"), .packageManagerCaches),
            Rule(.prefix(home + "/.gradle/caches"), .packageManagerCaches),
            Rule(.prefix(home + "/.m2/repository"), .packageManagerCaches),
            Rule(.prefix(home + "/Library/Caches/Homebrew"), .packageManagerCaches),
            Rule(.prefix(home + "/.cache/pip"), .packageManagerCaches),
            Rule(.prefix(home + "/.pub-cache"), .packageManagerCaches),
            Rule(.prefix(home + "/go/pkg/mod"), .packageManagerCaches),

            // --- Browsers: caches only, never profile or cookies ---
            // These are prefix rules, not exact ones: a browser nests its
            // profile directory inside the cache root, so an exact match would
            // classify every real cache as a generic app cache.
            Rule(.prefix(library + "/Caches/com.apple.Safari"), .browserCaches),
            Rule(.prefix(library + "/Caches/Google/Chrome"), .browserCaches),
            Rule(.prefix(library + "/Caches/Firefox"), .browserCaches),
            Rule(.prefix(library + "/Caches/Microsoft Edge"), .browserCaches),
            Rule(.prefix(library + "/Caches/com.microsoft.Edge"), .browserCaches),

            // --- System diagnostics ---
            Rule(.exact(library + "/Logs/DiagnosticReports"), .crashReports, risk: .disposable),
            Rule(.prefix(library + "/Logs"), .systemLogs),
            Rule(.exact("/Library/Logs/DiagnosticReports"), .crashReports, risk: .disposable),
            Rule(.prefix("/Library/Logs"), .systemLogs),
            Rule(.prefix("/var/log"), .systemLogs),

            // --- User media ---
            Rule(.prefix(home + "/Movies"), .largeMedia),
            Rule(.prefix(home + "/Pictures"), .largeMedia),
            Rule(.prefix(home + "/Music"), .largeMedia),

            // --- User-facing data ---
            Rule(.exact(library + "/Containers/com.apple.mail/Data/Library/Mail Downloads"), .mail, risk: .disposable),
            Rule(.exact(library + "/Mail"), .mail),
            Rule(.prefix(library + "/Containers/com.apple.mail"), .mail),
            Rule(.prefix(library + "/Messages"), .messages),
            Rule(.prefix(library + "/Containers/com.apple.iChat"), .messages),
            Rule(.prefix(home + "/Downloads"), .downloads),
            Rule(.exact(home + "/.Trash"), .trash),
            Rule(.prefix(home + "/.Trash"), .trash),
            Rule(.exact(home + "/Desktop"), .documents),
            Rule(.exact(home + "/Documents"), .documents),

            // --- App data ---
            Rule(.exact(library + "/Caches"), .applicationCaches),
            Rule(.prefix(library + "/Caches"), .applicationCaches),
            Rule(.exact("/Library/Caches"), .applicationCaches),
            Rule(.prefix("/Library/Caches"), .applicationCaches),
            Rule(.exact(library + "/Caches/com.apple.photos"), .applicationCaches),
            Rule(.prefix(library + "/Containers"), .containerData, risk: .caution),
            Rule(.prefix(library + "/Group Containers"), .containerData, risk: .caution),
            Rule(.prefix(library + "/Application Support"), .applicationSupport, risk: .caution),
            Rule(.prefix(library + "/Preferences"), .applicationSupport, risk: .caution),
            Rule(.prefix(library + "/HTTPStorages"), .applicationCaches),
            Rule(.prefix(library + "/WebKit"), .containerData, risk: .caution),
            Rule(.prefix(library + "/CloudStorage"), .applicationSupport, risk: .destructive),
            Rule(.prefix(library + "/Mobile Documents"), .applicationSupport, risk: .destructive),

            // --- Shared caches macOS uses for itself ---
            Rule(.exact("/Library/Updates"), .applicationCaches),
            Rule(.prefix("/private/var/folders"), .applicationCaches),
            Rule(.prefix("/private/var/vm"), .systemLogs),
            Rule(.exact("/private/var/db"), .applicationSupport, risk: .informational),

            // --- Applications ---
            Rule(.suffix("*.app"), .appBundles, risk: .informational),
            Rule(.suffix("*.framework"), .appBundles, risk: .informational),
        ]
    }

    public struct Classification: Sendable {
        public let category: DiskCategory
        public let risk: RiskLevel
        /// Set when a more specific rule applied than the generic parent folder.
        public let matchedRule: String
    }

    /// Classify one path.
    public func classify(path: String) -> Classification {
        let standardized = (path as NSString).standardizingPath
        let components = standardized.split(separator: "/").map(String.init)
        let last = components.last ?? standardized

        for rule in rules {
            if rule.matches(standardized, components: components, lastComponent: last) {
                return Classification(
                    category: rule.category,
                    risk: rule.riskOverride ?? rule.category.defaultRisk,
                    matchedRule: describe(rule.match)
                )
            }
        }

        // Fall back on the nearest ancestor that does match, so a deep unknown
        // folder still gets a sensible parent answer.
        var trimmed = standardized
        while let parent = (trimmed as NSString).deletingLastPathComponent as String?,
              parent != "/", !parent.isEmpty, parent != trimmed {
            trimmed = parent
            for rule in rules {
                if rule.matches(trimmed, components: trimmed.split(separator: "/").map(String.init), lastComponent: (trimmed as NSString).lastPathComponent) {
                    return Classification(
                        category: rule.category,
                        risk: rule.category.defaultRisk,
                        matchedRule: "inherited from \(trimmed)"
                    )
                }
            }
            if trimmed == "/" { break }
        }

        // Defer to the category's own default rather than restating it here, so
        // there is one place that decides how risky unidentified data is.
        return Classification(
            category: .other,
            risk: DiskCategory.other.defaultRisk,
            matchedRule: "no rule matched"
        )
    }

    public func classify(_ url: URL) -> Classification {
        classify(path: url.path)
    }

    private func describe(_ match: Match) -> String {
        switch match {
        case .prefix(let p): return "prefix \(p)"
        case .exact(let p): return "exact \(p)"
        case .component(let c): return "component \(c)"
        case .fileName(let n): return "file name \(n)"
        case .suffix(let s): return "suffix \(s)"
        }
    }
}
