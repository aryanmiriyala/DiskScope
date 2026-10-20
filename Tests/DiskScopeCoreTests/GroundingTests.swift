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
import DiskScopeAI

/// A `LanguageModel` that returns whatever the test tells it to, including
/// things a real model should never return.
///
/// This exists to prove the safety properties hold against a *hostile* backend,
/// not just a well-behaved one. If the validator only ever sees polite output
/// in tests, the guarantee is untested.
struct StubLanguageModel: LanguageModel {
    var backend: ModelBackend = .cloud
    var isAvailable: Bool = true
    var unavailableReason: String? = nil

    var groupings: [GroupingProposal] = []
    var answerToReturn: QueryAnswer = QueryAnswer(summary: "")

    func proposeGroupings(for digest: ScanDigest) async throws -> [GroupingProposal] {
        groupings
    }

    func answer(_ question: String, using digest: ScanDigest) async throws -> QueryAnswer {
        answerToReturn
    }
}

/// Builds a digest by hand so the AI tests do not need a real scan.
func makeTestDigest() -> ScanDigest {
    ScanDigest(
        entries: [
            ScanDigest.Entry(path: "/Users/me/Library/Caches/com.example.big", allocatedBytes: 3_000_000_000, fileCount: 4_200, newestModification: nil),
            ScanDigest.Entry(path: "/Users/me/Library/Caches/com.example.small", allocatedBytes: 500_000_000, fileCount: 90, newestModification: nil),
            ScanDigest.Entry(path: "/Users/me/projects/website/node_modules", allocatedBytes: 900_000_000, fileCount: 48_000, newestModification: nil),
            ScanDigest.Entry(path: "/Users/me/projects/api/node_modules", allocatedBytes: 400_000_000, fileCount: 22_000, newestModification: nil),
            ScanDigest.Entry(path: "/Users/me/Movies", allocatedBytes: 40_000_000_000, fileCount: 12, newestModification: nil),
        ],
        truncatedCount: 137,
        totalAllocatedBytes: 44_800_000_000,
        generatedAt: Date(timeIntervalSince1970: 1_800_000_000),
        unreadablePathCount: 4
    )
}

func registerGroundingTests() {
    test("digest: reports what it truncated and what was unreadable") {
        let digest = makeTestDigest()
        let summary = digest.compactSummary()

        // The model must be able to tell that its view is incomplete. Without
        // these lines it could imply it had seen the whole disk.
        try expect(summary.contains("137"), "truncation count should be stated")
        try expect(summary.lowercased().contains("unreadable"), "unreadable paths should be stated")
        try expect(summary.contains("44.8 GB"), "total should be formatted readably")
    }

    test("digest: admits only paths it actually measured") {
        let digest = makeTestDigest()
        try expect(digest.contains(path: "/Users/me/Movies"))
        try expect(!digest.contains(path: "/Users/me/Library/Something/Imaginary"))
        try expect(!digest.contains(path: "/etc/passwd"))
    }

    test("digest: totals are summed from measured entries") {
        let digest = makeTestDigest()
        let total = digest.totalAllocated(for: [
            "/Users/me/projects/website/node_modules",
            "/Users/me/projects/api/node_modules",
        ])
        try expectEqual(total, 1_300_000_000)
    }

    test("digest: totals return nil when any path is unknown") {
        let digest = makeTestDigest()
        let total = digest.totalAllocated(for: [
            "/Users/me/Movies",
            "/Users/me/does/not/exist",
        ])
        try expect(total == nil, "an unknown path must make the total unknown, not zero")
    }

    // MARK: The load-bearing guarantee

    test("validator: a proposal citing a path that was never scanned is rejected") {
        let digest = makeTestDigest()
        let proposals = [
            GroupingProposal(
                paths: ["/Users/me/projects/website/node_modules", "/Users/me/fabricated/thing"],
                suggestedCategory: .packageManagerCaches,
                rationale: "Node dependencies."
            ),
        ]

        let (accepted, rejected) = GroundingValidator.validate(proposals: proposals, against: digest)

        try expectEqual(accepted.count, 0, "a group containing a fabricated path is not trustworthy")
        try expectEqual(rejected.count, 1)
        try expect(rejected[0].paths.contains("/Users/me/fabricated/thing"))
    }

    test("validator: a hallucinated size claim cannot become a reported figure") {
        // QueryAnswer has no size field at all, so there is nowhere for a model
        // to put one. This test pins that: the number comes from the digest.
        let digest = makeTestDigest()
        let answer = QueryAnswer(
            summary: "Your movies folder is 40 GB.",
            citedPaths: ["/Users/me/Movies"]
        )
        let validated = GroundingValidator.validate(answer: answer, against: digest)

        // The prose still says "40 GB", because we do not rewrite model text.
        // What matters is that the number DiskScope *renders* is measured.
        try expectEqual(validated.measuredBytes(in: digest), 40_000_000_000)
        try expect(validated.citedPaths.contains("/Users/me/Movies"))
    }

    test("validator: unverified citations are surfaced rather than silently dropped") {
        let digest = makeTestDigest()
        let answer = QueryAnswer(
            summary: "Mixed answer.",
            citedPaths: ["/Users/me/Movies", "/Users/made/up/path"]
        )
        let validated = GroundingValidator.validate(answer: answer, against: digest)

        try expectEqual(validated.citedPaths, ["/Users/me/Movies"])
        try expect(validated.hasUnverifiedReferences, "the UI needs to know to warn the user")
        try expectEqual(validated.rejectedPaths, ["/Users/made/up/path"])
    }

    test("validator: overlapping groups do not double-count reclaimable space") {
        let digest = makeTestDigest()
        let proposals = [
            // A model asked twice can answer with overlapping groups.
            GroupingProposal(
                paths: ["/Users/me/Movies", "/Users/me/Library/Caches/com.example.big"],
                suggestedCategory: .largeMedia,
                rationale: "Big things."
            ),
            GroupingProposal(
                paths: ["/Users/me/Library/Caches/com.example.big", "/Users/me/Library/Caches/com.example.small"],
                suggestedCategory: .applicationCaches,
                rationale: "Caches."
            ),
        ]

        let (accepted, rejected) = GroundingValidator.validate(proposals: proposals, against: digest)

        // Every path must be claimed at most once, or summing the groups would
        // overstate how much space the user could reclaim.
        let allPaths = accepted.flatMap(\.paths)
        try expectEqual(
            Set(allPaths).count,
            allPaths.count,
            "no path may appear in more than one accepted group"
        )
        try expect(!rejected.isEmpty, "the overlap should be recorded as rejected")
    }

    test("validator: empty groups are rejected") {
        let digest = makeTestDigest()
        let (accepted, rejected) = GroundingValidator.validate(
            proposals: [GroupingProposal(paths: [], suggestedCategory: .other, rationale: "nothing")],
            against: digest
        )
        try expectEqual(accepted.count, 0)
        try expectEqual(rejected.count, 1)
    }

    test("validator: an unknown category from the model is dropped during parsing") {
        // The taxonomy is closed. A model inventing "CryptoWalletData" must not
        // become a new bucket in the user's report.
        let raw = """
        {"groups": [{"paths": ["/Users/me/Movies"], "category": "CryptoWalletData", "reason": "nope"}]}
        """
        let parsed = try GroupingParser.parse(raw)
        try expectEqual(parsed.count, 0, "unknown categories are discarded")
    }

    test("validator: a valid proposal survives intact") {
        let digest = makeTestDigest()
        let (accepted, rejected) = GroundingValidator.validate(proposals: [
            GroupingProposal(
                paths: ["/Users/me/projects/website/node_modules", "/Users/me/projects/api/node_modules"],
                suggestedCategory: .packageManagerCaches,
                rationale: "Both are Node dependency trees."
            ),
        ], against: digest)

        try expectEqual(accepted.count, 1)
        try expectEqual(rejected.count, 0)
        try expectEqual(accepted[0].measuredBytes(in: digest), 1_300_000_000)
    }

    // MARK: Response parsing

    test("parser: tolerates a markdown code fence around the JSON") {
        let raw = """
        Here you go:

        ```json
        {"summary": "Node dependencies.", "paths": ["/Users/me/projects/website/node_modules"]}
        ```
        """
        let answer = try GroupingParser.parseAnswer(raw)
        try expectEqual(answer.summary, "Node dependencies.")
        try expectEqual(answer.citedPaths.count, 1)
    }

    test("parser: rejects a response that is not JSON at all") {
        var threw = false
        do {
            _ = try GroupingParser.parseAnswer("I'm afraid I can't do that.")
        } catch {
            threw = true
        }
        try expect(threw, "prose instead of JSON should be an error, not an empty answer")
    }
}

func registerPromptTests() {
    test("prompt: the preamble forbids the model from stating sizes") {
        let preamble = PromptBuilder.systemPreamble.lowercased()
        try expect(preamble.contains("never state a size"))
        try expect(preamble.contains("never invent a path"))
    }

    test("prompt: the measured data is embedded in the request") {
        let digest = makeTestDigest()
        let prompt = PromptBuilder.queryRequest(
            question: "What is eating my space?",
            digest: digest,
            instructions: "cite paths"
        )
        try expect(prompt.contains("/Users/me/Movies"))
        try expect(prompt.contains("What is eating my space?"))
        try expect(prompt.contains("3000000000"), "raw byte counts are included for the model to reason about")
        try expect(!prompt.contains("3 GB"), "but never pre-formatted totals the model might parrot back")
    }
}

func registerBackendTests() {
    test("backend: on-device reports unavailable with a reason on this host") {
        let model = OnDeviceLanguageModel(availabilityOverride: false)
        try expect(!model.isAvailable)
        try expect(model.unavailableReason?.isEmpty == false, "an unavailable backend must say why")
        try expect(!model.backend.sendsDataOffDevice, "on-device models never send data off the machine")
    }

    test("backend: on-device reports available when forced on") {
        try expect(OnDeviceLanguageModel(availabilityOverride: true).isAvailable)
    }

    test("backend: an unavailable model throws rather than silently returning empty") {
        let model = OnDeviceLanguageModel(availabilityOverride: false)
        var threw = false
        do {
            _ = try await model.proposeGroupings(for: makeTestDigest())
        } catch {
            threw = true
        }
        try expect(threw, "silently returning zero groups would look like a successful scan")
    }

    test("backend: cloud is marked as sending data off device, local backends are not") {
        try expect(ModelBackend.cloud.sendsDataOffDevice)
        try expect(!ModelBackend.onDevice.sendsDataOffDevice)
        try expect(!ModelBackend.localServer.sendsDataOffDevice)
    }
}

func registerKeychainTests() {
    test("keychain: round-trips a key for a provider") {
        let store = KeychainStore()
        // A headless test binary may have no usable login keychain, in which
        // case there is nothing to assert. Skip rather than fail spuriously.
        guard (try? store.saveKey("sk-test-value-12345", for: .openAI)) != nil else {
            print("    (skipped: keychain unavailable to this process)")
            return
        }
        defer { try? store.deleteKey(for: .openAI) }

        try expectEqual(try store.key(for: .openAI), "sk-test-value-12345")
        try expect(store.hasKey(for: .openAI))
    }

    test("keychain: keys are scoped per provider") {
        let store = KeychainStore()
        guard (try? store.saveKey("sk-openai", for: .openAI)) != nil else {
            print("    (skipped: keychain unavailable to this process)")
            return
        }
        try? store.saveKey("sk-anthropic", for: .anthropic)
        defer {
            try? store.deleteAllKeys()
        }

        try expectEqual(try store.key(for: .openAI), "sk-openai")
        try expectEqual(try store.key(for: .anthropic), "sk-anthropic")
    }

    test("keychain: an empty key is rejected") {
        let store = KeychainStore()
        var threw = false
        do {
            try store.saveKey("   ", for: .openAI)
        } catch {
            threw = true
        }
        try expect(threw, "whitespace must not be stored as a credential")
    }
}
