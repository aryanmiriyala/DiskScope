import Foundation

/// A suggestion that a set of directories belong to one known category.
///
/// Note what is absent: there is no size field, and there is no confidence
/// score. A model's self-reported confidence is not a meaningful number, so
/// presenting one would invite the user to trust a number that was invented.
/// Group sizes are always summed by us from the measured paths.
public struct GroupingProposal: Sendable, Codable, Identifiable {
    /// Directory paths that share a category. All must exist in the digest.
    public let paths: [String]
    /// One of our existing categories. The model picks from the taxonomy; it
    /// does not get to invent a new bucket.
    public let suggestedCategory: DiskCategory
    /// Plain-English reason, shown to the user before they accept anything.
    public let rationale: String

    public var id: String { paths.sorted().joined(separator: "|") }

    public init(paths: [String], suggestedCategory: DiskCategory, rationale: String) {
        self.paths = paths
        self.suggestedCategory = suggestedCategory
        self.rationale = rationale
    }

    /// Measured total for this group, computed from the digest rather than
    /// reported by the model.
    public func measuredBytes(in digest: ScanDigest) -> Int64? {
        digest.totalAllocated(for: paths)
    }
}

/// An answer to a question about the scan.
///
/// Deliberately carries **no size, count or percentage**. The model can name
/// directories and explain them; the app derives every figure from the digest.
/// That is what keeps "what took up 40 GB?" answerable with a measured number
/// rather than a plausible guess.
public struct QueryAnswer: Sendable {
    /// Prose explanation, written to be read by the person who asked.
    public let summary: String
    /// Paths the answer refers to. Validated against the digest before use.
    public let citedPaths: [String]
    /// Paths that appeared in the answer but could not be verified. Populated
    /// by the validator, never by the model.
    public let rejectedPaths: [String]

    public init(summary: String, citedPaths: [String] = [], rejectedPaths: [String] = []) {
        self.summary = summary
        self.citedPaths = citedPaths
        self.rejectedPaths = rejectedPaths
    }

    /// Measured total across the verified paths.
    ///
    /// This is the only number the app will show for a model answer, and it is
    /// computed from `st_blocks`, not generated.
    public func measuredBytes(in digest: ScanDigest) -> Int64 {
        digest.totalAllocated(for: citedPaths) ?? 0
    }

    public var hasUnverifiedReferences: Bool { !rejectedPaths.isEmpty }
}

/// Which backend a `LanguageModel` implementation represents.
public enum ModelBackend: String, Sendable, Codable, CaseIterable, Identifiable {
    /// Apple's on-device model. Nothing leaves the Mac. Needs macOS 26 on
    /// Apple Silicon.
    case onDevice
    /// A user's own API key against a hosted provider. Data does leave.
    case cloud
    /// A user-run server such as Ollama on localhost.
    case localServer

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .onDevice: return "On-device (Apple)"
        case .cloud: return "Cloud API (your key)"
        case .localServer: return "Local server"
        }
    }

    /// Whether using this backend sends filesystem paths off the machine.
    ///
    /// The UI gates its consent flow on this, which is why it lives on the
    /// backend rather than being inferred at the call site.
    public var sendsDataOffDevice: Bool {
        switch self {
        case .onDevice, .localServer: return false
        case .cloud: return true
        }
    }
}

/// A source of language model completions.
///
/// The protocol lives in `DiskScopeCore` so the pure, offline library stays
/// free of networking and Keychain code, and so every backend is testable
/// against a stub. Implementations live in `DiskScopeAI`.
public protocol LanguageModel: Sendable {
    var backend: ModelBackend { get }

    /// Whether this backend can actually run right now.
    ///
    /// On-device reports false below macOS 26. Cloud reports false when no key
    /// is configured. The UI uses this to explain *why* rather than just
    /// greying out a menu item.
    var isAvailable: Bool { get }

    /// A user-facing explanation when `isAvailable` is false.
    var unavailableReason: String? { get }

    /// Propose categories for directories the rule table could not classify.
    func proposeGroupings(for digest: ScanDigest) async throws -> [GroupingProposal]

    /// Answer a question using only measured data from `digest`.
    func answer(_ question: String, using digest: ScanDigest) async throws -> QueryAnswer
}

public enum LanguageModelError: LocalizedError, Sendable {
    case unavailable(String)
    case noAPIKey
    case requestFailed(status: Int, detail: String)
    case malformedResponse(String)
    case responseFailedValidation([String])

    public var errorDescription: String? {
        switch self {
        case .unavailable(let reason):
            return reason
        case .noAPIKey:
            return "No API key is configured for this provider."
        case .requestFailed(let status, let detail):
            // The provider's own message is included because it is usually the
            // only thing that distinguishes a rate limit from a bad key.
            return "The model provider returned HTTP \(status). \(detail)"
        case .malformedResponse(let detail):
            return "The model returned a response DiskScope could not read. \(detail)"
        case .responseFailedValidation(let problems):
            return "The model's answer referenced data that was not in the scan and was discarded: \(problems.joined(separator: ", "))"
        }
    }
}
