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

/// Proves the CryptoKit fast path and the dependency-free reference
/// implementation produce identical digests.
///
/// This matters more than it looks. The fast path is ~1,200x faster and is what
/// duplicate detection will actually use, while the reference is what the
/// SHA-256 test vectors check. If the two ever diverged, duplicate detection
/// would silently stop finding anything while the vector tests still passed —
/// each implementation agreeing with itself.
func registerCryptoAgreementTests() {
    let lengths = [0, 1, 55, 56, 63, 64, 65, 119, 120, 127, 128, 191, 192, 1000, 65_536, 100_000]

    test("hash: crypto fast path matches the reference implementation in memory") {
        for length in lengths {
            let payload = Data((0..<length).map { UInt8(($0 &* 31 &+ 7) % 256) })
            try expectEqual(
                SHA256Lite.sha256Hex(of: SHA256Lite.digest(of: payload)),
                SHA256Lite.sha256Hex(of: SHA256Lite.referenceDigest(of: payload)),
                "implementations disagree at length \(length)"
            )
        }
    }

    test("hash: crypto fast path matches the reference when streaming a file") {
        let tree = try TempTree()
        for length in [0, 1, 4096, 65_537, 300_000] {
            let url = tree.url("agree-\(length).bin")
            try Data((0..<length).map { UInt8($0 % 251) }).write(to: url)

            let fast = SHA256Lite.hexString(try SHA256Lite.digest(ofFileAt: url))
            let reference = SHA256Lite.hexString(try SHA256Lite.referenceDigest(ofFileAt: url))
            try expectEqual(fast, reference, "streaming implementations disagree at length \(length)")

            // And against the system's own implementation, for good measure.
            try expectEqual(fast, shellSHA256(ofFileAt: url), "disagrees with shasum at length \(length)")
        }
    }

    test("hash: chunked reads do not change the digest") {
        let tree = try TempTree()
        let payload = Data((0..<200_000).map { UInt8($0 % 97) })
        let url = tree.url("chunked.bin")
        try payload.write(to: url)

        let oneMegabyte = SHA256Lite.hexString(try SHA256Lite.digest(ofFileAt: url, chunkSize: 1 << 20))
        let eightKilobyte = SHA256Lite.hexString(try SHA256Lite.digest(ofFileAt: url, chunkSize: 8 * 1024))

        try expectEqual(oneMegabyte, eightKilobyte, "read size must not affect the digest")
        try expectEqual(oneMegabyte, shellSHA256(ofFileAt: url))
    }

    test("hash: sample digest agrees with the full digest for identical files") {
        let tree = try TempTree()
        let a = tree.url("a.bin")
        let b = tree.url("b.bin")
        let payload = Data((0..<100_000).map { UInt8($0 % 199) })
        try payload.write(to: a)
        try payload.write(to: b)

        let sampledA = try SHA256Lite.sampleDigest(ofFileAt: a, fileSize: 100_000)
        let sampledB = try SHA256Lite.sampleDigest(ofFileAt: b, fileSize: 100_000)
        try expectEqual(sampledA, sampledB, "identical files must sample identically")

        // A sampled digest is a *shortlist* filter, not a full digest, so it is
        // not expected to equal the full hash. Confirming that distinction keeps
        // the duplicate finder honest: sampling must never be reported as proof.
        let full = try SHA256Lite.digest(ofFileAt: a)
        try expect(sampledA != full, "sampled digest must not be treated as a full hash")
    }
}
