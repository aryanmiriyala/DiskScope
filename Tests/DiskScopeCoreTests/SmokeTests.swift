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

func registerHashTests() {
    test("hash: matches the known SHA-256 vector for \"abc\"") {
        try expectEqual(
            SHA256Lite.sha256Hex(of: "abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }

    test("hash: matches the known SHA-256 vector for the empty input") {
        try expectEqual(
            SHA256Lite.sha256Hex(of: Data()),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        )
    }

    test("hash: chunked and single-shot updates agree") {
        // Longer than the 64-byte block boundary, to exercise the buffering and
        // bit-length encoding paths that only trigger on multi-block input.
        let payload = Data(repeating: 0x61, count: 1_000_000)

        var chunked = SHA256Lite.Hasher()
        let bytes = [UInt8](payload)
        var offset = 0
        while offset < bytes.count {
            let end = min(offset + 4096, bytes.count)
            chunked.update(bytes[offset..<end])
            offset = end
        }

        var oneShot = SHA256Lite.Hasher()
        oneShot.update(payload)

        try expectEqual(
            SHA256Lite.sha256Hex(of: chunked.finalize()),
            SHA256Lite.sha256Hex(of: oneShot.finalize())
        )
    }

    test("hash: payload size that is an exact multiple of the block size") {
        // 200,000 is exactly 3125 SHA-256 blocks, so the buffer lands empty
        // after the last compress(). That boundary is where padding bugs hide.
        let payload = Data((0..<200_000).map { UInt8($0 % 251) })
        try expectEqual(
            SHA256Lite.sha256Hex(of: payload),
            "e24bc62381f1224fbbb74688663f8f9743b9680b193edd666835e97b06e730eb"
        )
    }

    test("hash: streaming a file matches hashing its bytes in memory") {
        let tree = try TempTree()
        let bytes = Data((0..<200_000).map { UInt8($0 % 251) })
        let url = tree.url( "payload.bin")
        try bytes.write(to: url)

        let streamed = SHA256Lite.hexString(try SHA256Lite.digest(ofFileAt: url))
        try expectEqual(streamed, SHA256Lite.sha256Hex(of: bytes))
    }

    test("hash: streaming across chunk boundaries matches a single read") {
        let tree = try TempTree()
        let bytes = Data((0..<300_000).map { UInt8($0 % 97) })
        let url = tree.url( "chunked.bin")
        try bytes.write(to: url)

        // A 64 KB read size forces many short reads across the file.
        let streamed = SHA256Lite.hexString(try SHA256Lite.digest(ofFileAt: url, chunkSize: 64 * 1024))
        try expectEqual(streamed, SHA256Lite.sha256Hex(of: bytes))
    }

    test("hash: every length across two block boundaries pads correctly") {
        // Lengths 0...192 cover every residue class modulo 64 three times over,
        // including 55, 56, 63 and 64, which are where padding implementations
        // traditionally break. Digests are cross-checked against `shasum`.
        let lengths = [0, 1, 54, 55, 56, 57, 63, 64, 65, 119, 120, 127, 128, 191, 192]
        for length in lengths {
            let payload = Data((0..<length).map { UInt8(($0 &* 31 &+ 7) % 256) })
            let file = URL(fileURLWithPath: NSTemporaryDirectory())
                .appending(path: "diskscope-hash-\(UUID().uuidString).bin")
            defer { try? FileManager.default.removeItem(at: file) }
            try payload.write(to: file)

            let streamed = SHA256Lite.hexString(try SHA256Lite.digest(ofFileAt: file))
            let inMemory = SHA256Lite.sha256Hex(of: payload)

            try expectEqual(inMemory, streamed, "streamed and in-memory digests differ at length \(length)")

            let reference = shellSHA256(ofFileAt: file)
            try expectEqual(
                streamed,
                reference,
                "digest at length \(length) disagrees with /usr/bin/shasum"
            )
        }
    }

    test("hash: sample digest distinguishes files differing only at the tail") {
        let tree = try TempTree()
        let a = tree.url( "a.bin")
        let b = tree.url( "b.bin")

        let first = Data(repeating: 0xAA, count: 500_000)
        try first.write(to: a)

        var second = first
        second[499_999] = 0xBB
        try second.write(to: b)

        let hashA = try SHA256Lite.sampleDigest(ofFileAt: a, fileSize: 500_000)
        let hashB = try SHA256Lite.sampleDigest(ofFileAt: b, fileSize: 500_000)

        // Sampling the tail is what catches this. A head-only hash would collide.
        try expect(hashA != hashB, "sampling head and tail should separate these")
    }
}
