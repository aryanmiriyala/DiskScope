import Foundation

/// A counting semaphore that async tasks can wait on.
///
/// Scanning a home directory means fanning out over hundreds of thousands of
/// directories. Unbounded fan-out exhausts file descriptors and thrashes the
/// SSD, which is slower than a smaller number of concurrent walks. Every
/// directory scan acquires a permit before it opens a directory handle.
public actor AsyncSemaphore {
    private var permits: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(permits: Int) {
        self.permits = max(1, permits)
    }

    public func acquire() async {
        if permits > 0 {
            permits -= 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    public func release() {
        if waiters.isEmpty {
            permits += 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}
