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

/// Builds a throwaway tree on disk so scanner behaviour can be asserted against
/// something whose contents we know exactly.
///
/// Scanner tests are only meaningful if the expected byte counts are
/// derivable from the test itself, not from a fixture that could drift.
final class TempTree {
    let root: URL

    init(name: String = "diskscope-tests-\(UUID().uuidString.prefix(8))") throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: name)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    /// Write a file of `bytes` bytes, creating parent directories as needed.
    @discardableResult
    func writeFile(_ relativePath: String, bytes: Int) throws -> URL {
        let url = root.appending(path: relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(repeating: 0x41, count: bytes).write(to: url)
        return url
    }

    @discardableResult
    func makeDirectory(_ relativePath: String) throws -> URL {
        let url = root.appending(path: relativePath)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func url(_ relativePath: String) -> URL {
        root.appending(path: relativePath)
    }
}

/// SHA-256 of a file, computed by `/usr/bin/shasum`.
///
/// Having an independent implementation to compare against is what makes the
/// in-house hasher trustworthy. A bug that affects every one of our own tests
/// consistently cannot be caught by more tests of the same code, so we check
/// against the system's `shasum` instead.
func shellSHA256(ofFileAt url: URL) -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/shasum")
    process.arguments = ["-a", "256", url.path]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice

    do {
        try process.run()
    } catch {
        return "<shasum unavailable>"
    }

    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()

    // Output looks like "<64 hex chars>  <path>".
    let text = String(decoding: data, as: UTF8.self)
    return text.split(separator: " ").first.map(String.init) ?? "<no output>"
}
