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

/// A minimal test harness.
///
/// DiskScope deliberately avoids build-time dependencies so that it can be
/// compiled and verified with nothing but a Swift toolchain — no Xcode, no
/// package resolution, no network. That rules out XCTest and swift-testing,
/// neither of which is present in the Command Line Tools, so this provides the
/// small slice of either API that the suite actually uses.
///
/// The API deliberately mirrors swift-testing's shape (`expect`, `require`,
/// throwing test bodies) so that migrating to it later, on a machine with full
/// Xcode, is a mechanical import swap rather than a rewrite.
public struct TestFailure: Error, CustomStringConvertible {
    public let description: String
    init(_ description: String) { self.description = description }
}

public typealias TestBody = @Sendable () async throws -> Void

public struct RegisteredTest: Sendable {
    public let name: String
    public let body: TestBody
}

/// Global registry, populated at startup and read once by the runner.
public final class TestRegistry: @unchecked Sendable {
    public static let shared = TestRegistry()

    private let lock = NSLock()
    private var storage: [RegisteredTest] = []

    func add(_ name: String, _ body: @escaping TestBody) {
        lock.lock()
        storage.append(RegisteredTest(name: name, body: body))
        lock.unlock()
    }

    public var tests: [RegisteredTest] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

/// Declare a test. Bodies are `async throws` because the scanner is async and
/// most of the interesting assertions are about it.
public func test(_ name: String, _ body: @escaping TestBody) {
    TestRegistry.shared.add(name, body)
}

// MARK: - Assertions

public func expect(
    _ condition: Bool,
    _ message: @autoclosure () -> String = "condition was false",
    file: StaticString = #filePath,
    line: UInt = #line
) throws {
    guard !condition else { return }
    throw TestFailure("\(message())  (\(shortFile(file)):\(line))")
}

public func expectEqual<T: Equatable>(
    _ actual: T,
    _ expected: T,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) throws {
    guard actual == expected else {
        let label = message().isEmpty ? "" : "\(message()) — "
        throw TestFailure("\(label)expected \(expected), got \(actual)  (\(shortFile(file)):\(line))")
    }
}

public func expectLessThan<T: Comparable>(
    _ actual: T,
    _ limit: T,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) throws {
    guard actual < limit else {
        let label = message().isEmpty ? "" : "\(message()) — "
        throw TestFailure("\(label)expected < \(limit), got \(actual)  (\(shortFile(file)):\(line))")
    }
}

public func expectGreaterThanOrEqual<T: Comparable>(
    _ actual: T,
    _ limit: T,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) throws {
    guard actual >= limit else {
        let label = message().isEmpty ? "" : "\(message()) — "
        throw TestFailure("\(label)expected >= \(limit), got \(actual)  (\(shortFile(file)):\(line))")
    }
}

/// Unwrap an optional or fail with context, mirroring `try #require`.
public func require<T>(
    _ value: T?,
    _ message: @autoclosure () -> String = "required value was nil",
    file: StaticString = #filePath,
    line: UInt = #line
) throws -> T {
    guard let value else {
        throw TestFailure("\(message())  (\(shortFile(file)):\(line))")
    }
    return value
}

private func shortFile(_ file: StaticString) -> String {
    URL(fileURLWithPath: "\(file)").lastPathComponent
}

// MARK: - Runner

public enum TestRunner {
    public static func run(filter: String? = nil) async -> Int32 {
        let tests = TestRegistry.shared.tests
        let selected = tests.filter { test in
            guard let filter else { return true }
            return test.name.localizedCaseInsensitiveContains(filter)
        }

        guard !selected.isEmpty else {
            print("No tests matched \"\(filter ?? "")\".")
            return 1
        }

        var passed = 0
        var failures: [(String, String)] = []
        let start = Date()

        for test in selected {
            let testStart = Date()
            do {
                try await test.body()
                let elapsed = String(format: "%.0fms", Date().timeIntervalSince(testStart) * 1000)
                print("  \u{2713} \(test.name)  (\(elapsed))")
                passed += 1
            } catch let failure as TestFailure {
                print("  \u{2717} \(test.name)")
                failures.append((test.name, failure.description))
            } catch {
                print("  \u{2717} \(test.name)")
                failures.append((test.name, "\(type(of: error)): \(error)"))
            }
        }

        let elapsed = String(format: "%.2fs", Date().timeIntervalSince(start))
        print("")

        if failures.isEmpty {
            print("All \(passed) tests passed in \(elapsed).")
            return 0
        }

        print("\(failures.count) failure\(failures.count == 1 ? "" : "s"):")
        for (name, detail) in failures {
            print("  \(name)")
            print("    \(detail)")
        }
        print("")
        print("\(passed) passed, \(failures.count) failed in \(elapsed).")
        return 1
    }
}
