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

/// BYOK cloud backend, speaking the OpenAI chat-completions shape.
///
/// Anthropic uses a different request and response format, so it gets its own
/// request builder rather than being forced through a lowest-common-denominator
/// wrapper. Anything OpenAI-compatible — including local servers such as Ollama
/// and llama.cpp — reuses the OpenAI path with a different base URL.
public actor CloudLanguageModel: LanguageModel {
    public nonisolated let backend: ModelBackend = .cloud

    private let provider: KeychainStore.Provider
    private let keychain: KeychainStore
    private let baseURL: URL
    private let modelIdentifier: String
    private let session: URLSession

    public init(
        provider: KeychainStore.Provider,
        baseURL: URL,
        modelIdentifier: String,
        keychain: KeychainStore = KeychainStore(),
        session: URLSession = .shared
    ) {
        self.provider = provider
        self.baseURL = baseURL
        self.modelIdentifier = modelIdentifier
        self.keychain = keychain
        self.session = session
    }

    public nonisolated var isAvailable: Bool {
        (try? keychain.key(for: provider))?.isEmpty == false
    }

    public nonisolated var unavailableReason: String? {
        isAvailable ? nil : "Add an API key for \(provider.title) in Settings to use cloud models."
    }

    // MARK: - LanguageModel

    public func proposeGroupings(for digest: ScanDigest) async throws -> [GroupingProposal] {
        let schema = """
        Respond with JSON only, matching this shape:
        {"groups": [{"paths": ["<exact path>", ...], "category": "<category id>", "reason": "<one sentence>"}]}

        Rules:
        - Use ONLY path strings copied exactly from the list below.
        - Choose category only from: \(allowedCategoryIDs.joined(separator: ", ")).
        - Group every path that is not in an existing category. Do not skip any.
        - Do not include sizes, byte counts or totals. DiskScope measures those itself.
        """

        let request = PromptBuilder.groupingRequest(digest: digest, instructions: schema)
        let raw = try await send(prompt: request)

        return try parseGroups(from: raw)
    }

    public func answer(_ question: String, using digest: ScanDigest) async throws -> QueryAnswer {
        let schema = """
        Respond with JSON only, matching this shape:
        {"summary": "<two or three sentences of plain English>", "paths": ["<exact path>", ...]}

        Rules:
        - Use ONLY path strings copied exactly from the list below.
        - Cite every path you refer to in "paths".
        - Do NOT state any size, byte count or percentage. Write "the X folder"
          instead of "the 4 GB folder". DiskScope attaches the real measured
          size to whatever you cite.
        """

        let request = PromptBuilder.queryRequest(
            question: question,
            digest: digest,
            instructions: schema
        )
        let raw = try await send(prompt: request)
        return try parseAnswer(from: raw)
    }

    // MARK: - Networking

    private func send(prompt: String) async throws -> String {
        guard let key = try keychain.key(for: provider), !key.isEmpty else {
            throw LanguageModelError.noAPIKey
        }

        var request = URLRequest(url: baseURL.appending(path: "chat/completions"))
        request.httpMethod = "POST"
        request.timeoutInterval = 60

        let body: [String: Any] = [
            "model": modelIdentifier,
            "messages": [
                ["role": "system", "content": PromptBuilder.systemPreamble],
                ["role": "user", "content": prompt],
            ],
            // Low temperature: we want faithful reading of the supplied list,
            // not creative suggestions about what the user might delete.
            "temperature": 0,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        switch provider {
        case .openAI, .openAICompatible:
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        case .anthropic:
            request.setValue("x-api-key", forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw LanguageModelError.malformedResponse("No HTTP response.")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw LanguageModelError.requestFailed(
                status: http.statusCode,
                detail: Self.errorDetail(from: data)
            )
        }

        return try extractText(from: data)
    }

    /// Pull the assistant message out of a chat-completions response.
    private func extractText(from data: Data) throws -> String {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LanguageModelError.malformedResponse("Response was not a JSON object.")
        }

        // OpenAI shape.
        if let choices = json["choices"] as? [[String: Any]],
           let message = choices.first?["message"] as? [String: Any],
           let content = message["content"] as? String {
            return content
        }

        // Anthropic shape.
        if let blocks = json["content"] as? [[String: Any]],
           let text = blocks.compactMap({ $0["text"] as? String }).first {
            return text
        }

        throw LanguageModelError.malformedResponse("No message content in the response.")
    }

    private static func errorDetail(from data: Data) -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return String(decoding: data.prefix(300), as: UTF8.self)
        }
        if let error = json["error"] as? [String: Any],
           let message = error["message"] as? String {
            return message
        }
        return String(decoding: data.prefix(300), as: UTF8.self)
    }

    // MARK: - Response parsing

    /// Parse the JSON the model was asked for, tolerating a markdown fence.
    ///
    /// Wrapping JSON in ```json fences is near-universal model behaviour and
    /// failing on it would make the feature look broken for no good reason.
    private func extractJSONObject(from raw: String) throws -> [String: Any] {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```"), let newline = text.firstIndex(of: "\n") {
            // Drop the opening fence and any language tag on the same line.
            text = String(text[text.index(after: newline)...])
            if text.hasSuffix("```") {
                text = String(text.dropLast(3))
            }
            if text.lowercased().hasPrefix("json") {
                text = String(text.dropFirst(4))
            }
        }

        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LanguageModelError.malformedResponse("Expected a JSON object.")
        }
        return object
    }

    private func parseGroups(from raw: String) throws -> [GroupingProposal] {
        let object = try extractJSONObject(from: raw)
        guard let groups = object["groups"] as? [[String: Any]] else {
            throw LanguageModelError.malformedResponse("No \"groups\" array in the response.")
        }

        return groups.compactMap { group in
            guard let paths = group["paths"] as? [String], !paths.isEmpty else { return nil }
            // An unknown category is dropped rather than guessed at.
            guard let categoryID = group["category"] as? String,
                  let category = DiskCategory(rawValue: categoryID) else { return nil }
            return GroupingProposal(
                paths: paths,
                suggestedCategory: category,
                rationale: (group["reason"] as? String) ?? ""
            )
        }
    }

    private func parseAnswer(from raw: String) throws -> QueryAnswer {
        let object = try extractJSONObject(from: raw)
        let summary = (object["summary"] as? String) ?? ""
        let paths = (object["paths"] as? [String]) ?? []
        return QueryAnswer(summary: summary, citedPaths: paths)
    }

    private var allowedCategoryIDs: [String] {
        DiskCategory.allCases.map(\.rawValue)
    }
}
