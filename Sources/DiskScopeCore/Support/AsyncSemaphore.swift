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

/// A counting semaphore that async tasks can wait on.
///
/// Scanning a filesystem means opening many directories at once. Unbounded
/// fan-out exhausts file descriptors, so each directory walk takes a permit for
/// the duration of its own enumeration — and only its own enumeration.
///
/// The scoping matters enormously. An earlier version held the permit across a
/// directory's entire recursive subtree, which deadlocks the moment the number
/// of concurrently blocked directories exceeds the permit count: every ancestor
/// is holding a permit while waiting for a child that cannot acquire one. The
/// tree stops making progress and the scan hangs forever, on any input.
public final class AsyncSemaphore: @unchecked Sendable {
    private let lock = NSLock()
    private var permits: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(permits: Int) {
        self.permits = max(1, permits)
    }

    public func acquire() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if permits > 0 {
                permits -= 1
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    public func release() {
        lock.lock()
        if waiters.isEmpty {
            permits += 1
            lock.unlock()
        } else {
            let next = waiters.removeFirst()
            lock.unlock()
            next.resume()
        }
    }

    /// Run `body` while holding a permit.
    ///
    /// The release happens synchronously in a `defer`, rather than by spawning a
    /// task to do it. Spawning a task per directory is a measurable cost when
    /// there are hundreds of thousands of them.
    public func withPermit<T>(_ body: () async -> T) async -> T {
        await acquire()
        defer { release() }
        return await body()
    }
}
