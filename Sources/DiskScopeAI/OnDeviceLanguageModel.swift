import Foundation
import DiskScopeCore

#if canImport(FoundationModels)
import FoundationModels
#endif

/// Apple's on-device model. Nothing leaves the Mac.
///
/// This is the default backend when the hardware supports it, and the reason
/// the AI features are worth having at all for someone who would rather not ship
/// their directory listing to a hosted API.
///
/// Availability: requires macOS 26 on Apple Silicon. On anything else
/// `isAvailable` is false and `unavailableReason` explains exactly why, so the
/// UI can offer a fallback rather than showing a dead menu item.
public struct OnDeviceLanguageModel: LanguageModel {
    public nonisolated let backend: ModelBackend = .onDevice

    /// Injected so tests can exercise availability and the unavailable path
    /// without depending on the host's hardware.
    private let availabilityOverride: Bool?

    public init(availabilityOverride: Bool? = nil) {
        self.availabilityOverride = availabilityOverride
    }

    public var isAvailable: Bool {
        if let override = availabilityOverride { return override }
        return Self.systemIsCapable
    }

    public var unavailableReason: String? {
        if isAvailable { return nil }
        if #available(macOS 26.0, *) {
            return "The on-device model could not be loaded. It may still be downloading in Settings › Apple Intelligence."
        } else {
            return "On-device models need macOS 26 on Apple Silicon. Use a cloud API key or a local server instead."
        }
    }

    public func proposeGroupings(for digest: ScanDigest) async throws -> [GroupingProposal] {
        guard isAvailable else { throw LanguageModelError.unavailable(unavailableReason ?? "Unavailable") }
        guard #available(macOS 26.0, *) else {
            throw LanguageModelError.unavailable(unavailableReason ?? "Unavailable")
        }

        let schema = """
        {"groups": [{"paths": [...], "category": "<id>", "reason": "<one sentence>"}]}
        """

        let prompt = PromptBuilder.groupingRequest(
            digest: digest,
            instructions: """
            Respond with JSON only: \(schema)
            Use only exact paths from the list. Category must be one of: \
            \(DiskCategory.allCases.map(\.rawValue).joined(separator: ", ")).
            Do not include any sizes.
            """
        )

        let text = try await generate(prompt: prompt)
        return try GroupingParser.parse(text)
    }

    public func answer(_ question: String, using digest: ScanDigest) async throws -> QueryAnswer {
        guard isAvailable else { throw LanguageModelError.unavailable(unavailableReason ?? "Unavailable") }
        guard #available(macOS 26.0, *) else {
            throw LanguageModelError.unavailable(unavailableReason ?? "Unavailable")
        }

        let prompt = PromptBuilder.queryRequest(
            question: question,
            digest: digest,
            instructions: """
            Respond with JSON only: {"summary": "...", "paths": [...]}
            Use only exact paths from the list. Never state a size.
            """
        )

        let text = try await generate(prompt: prompt)
        return try GroupingParser.parseAnswer(text)
    }

    // MARK: - FoundationModels bridge

    @available(macOS 26.0, *)
    private func generate(prompt: String) async throws -> String {
        let session = LanguageModelSession(instructions: PromptBuilder.systemPreamble)

        do {
            let response = try await session.respond(to: prompt)
            return response.content
        } catch {
            throw LanguageModelError.malformedResponse(error.localizedDescription)
        }
    }

    private static var systemIsCapable: Bool {
        #if arch(arm64)
        if #available(macOS 26.0, *) {
            // `SystemLanguageModel.default.availability` reflects whether the
            // model has actually been downloaded, which is a separate question
            // from whether the OS supports it.
            switch SystemLanguageModel.default.availability {
            case .available:
                return true
            case .unavailable:
                return false
            @unknown default:
                return false
            }
        }
        #endif
        return false
    }
}

/// Shared JSON parsing for backends that both ask for the same shapes.
///
/// Extracted so the on-device and cloud paths cannot drift apart in how lenient
/// they are — a difference there would be a confusing bug for users.
///
/// Public so the test suite can exercise the parsing and fence tolerance
/// directly, rather than only through a live network call.
public enum GroupingParser {
    public static func parse(_ raw: String) throws -> [GroupingProposal] {
        let object = try jsonObject(from: raw)
        guard let groups = object["groups"] as? [[String: Any]] else {
            throw LanguageModelError.malformedResponse("No \"groups\" array.")
        }
        return groups.compactMap { group in
            guard let paths = group["paths"] as? [String], !paths.isEmpty,
                  let categoryID = group["category"] as? String,
                  let category = DiskCategory(rawValue: categoryID)
            else { return nil }
            return GroupingProposal(
                paths: paths,
                suggestedCategory: category,
                rationale: (group["reason"] as? String) ?? ""
            )
        }
    }

    public static func parseAnswer(_ raw: String) throws -> QueryAnswer {
        let object = try jsonObject(from: raw)
        return QueryAnswer(
            summary: (object["summary"] as? String) ?? "",
            citedPaths: (object["paths"] as? [String]) ?? []
        )
    }

    /// Tolerates the shapes models actually return: bare JSON, JSON in a
    /// markdown fence, or JSON wrapped in a sentence of preamble. Models are
    /// inconsistent about this even when explicitly told to emit only JSON, and
    /// failing on a stray "Here you go:" would make the feature look broken for
    /// no good reason.
    public static func jsonObject(from raw: String) throws -> [String: Any] {
        if let object = decode(raw) { return object }

        // Fall back to the outermost brace-delimited span.
        if let start = raw.firstIndex(of: "{"),
           let end = raw.lastIndex(of: "}") {
            if let object = decode(String(raw[start...end])) { return object }
        }

        throw LanguageModelError.malformedResponse("Expected a JSON object.")
    }

    /// Strip a markdown fence if present, then decode.
    private static func decode(_ text: String) -> [String: Any]? {
        var candidate = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if candidate.hasPrefix("```"), let newline = candidate.firstIndex(of: "\n") {
            candidate = String(candidate[candidate.index(after: newline)...])
            if candidate.hasSuffix("```") {
                candidate = String(candidate.dropLast(3))
            }
            if candidate.lowercased().hasPrefix("json") {
                candidate = String(candidate.dropFirst(4))
            }
        }
        guard let data = candidate.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object
    }
}
