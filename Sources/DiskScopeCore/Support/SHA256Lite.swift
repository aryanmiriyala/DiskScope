import Foundation

#if canImport(CryptoKit)
import CryptoKit
#endif

/// Minimal SHA-256, used for duplicate fingerprinting and short file hashing.
///
/// DiskScope's only real need is "are these two files the same bytes", and it
/// needs it to run over tens of gigabytes. A self-contained implementation keeps
/// the tool dependency-free, which matters for something people are being asked
/// to point at their home directory. Where CryptoKit is available we prefer it,
/// because it is hardware-accelerated; this is the portable fallback and the
/// reference implementation the tests check against.
public enum SHA256Lite {
    private static let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]

    /// Streaming hasher, so we never need the whole file in memory.
    ///
    /// `read(upToCount:)` returns short reads freely — a file spanning several
    /// APFS extents or sitting on a network volume can stop at any byte — so the
    /// loop feeds whatever it got until it gets nothing.
    public static func digest(ofFileAt url: URL, chunkSize: Int = 1 << 20) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        #if canImport(CryptoKit)
        // Apple's implementation runs at hardware speed. The portable fallback
        // below manages roughly 1 MB/s on this workload, which would take hours
        // over a real home directory, so this is not a micro-optimisation.
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return Data(hasher.finalize())
        #else
        var hasher = Hasher()
        while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
            hasher.update(chunk)
        }
        return hasher.finalize()
        #endif
    }

    /// Lowercase hex of the SHA-256 digest of `data`.
    public static func sha256Hex(of data: Data) -> String {
        hexString(digest(of: data))
    }

    /// Render an already-computed digest as lowercase hex.
    ///
    /// Separate from `sha256Hex` on purpose. Both take `Data`, but one hashes
    /// its input and the other only formats it — having two functions with the
    /// same signature and opposite meaning is a reliable way to accidentally
    /// hash a digest twice.
    public static func hexString(_ digest: Data) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Lowercase hex of the SHA-256 digest of a string's UTF-8 bytes.
    public static func sha256Hex(of string: String) -> String {
        sha256Hex(of: Data(string.utf8))
    }

    /// SHA-256 of in-memory bytes.
    public static func digest(of data: Data) -> Data {
        #if canImport(CryptoKit)
        return Data(SHA256.hash(data: data))
        #else
        var hasher = Hasher()
        hasher.update(data)
        return hasher.finalize()
        #endif
    }

    /// Digest via the dependency-free implementation.
    ///
    /// Kept public and used by the test suite to prove the CryptoKit fast path
    /// agrees with the reference implementation byte for byte. A correctness
    /// test that only ever exercises the fast path would agree with itself.
    public static func referenceDigest(of data: Data) -> Data {
        var hasher = Hasher()
        hasher.update(data)
        return hasher.finalize()
    }

    public static func referenceDigest(ofFileAt url: URL, chunkSize: Int = 1 << 20) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = Hasher()
        while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
            hasher.update(chunk)
        }
        return hasher.finalize()
    }

    /// Hash only the head and tail of a file.
    ///
    /// Two files with the same size, first `headBytes` and last `tailBytes` are
    /// overwhelmingly likely to be duplicates, and sampling 128 KB of a 4 GB file
    /// is effectively instant where a full hash would take minutes. Callers
    /// confirm the shortlist with a full hash before reporting anything.
    public static func sampleDigest(
        ofFileAt url: URL,
        fileSize: Int64,
        headBytes: Int = 64 * 1024,
        tailBytes: Int = 64 * 1024
    ) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        #if canImport(CryptoKit)
        var hasher = SHA256()
        if fileSize > 0 {
            hasher.update(data: try handle.read(upToCount: headBytes) ?? Data())
        }
        if fileSize > Int64(headBytes + tailBytes) {
            try handle.seek(toOffset: UInt64(max(0, fileSize - Int64(tailBytes))))
            hasher.update(data: try handle.read(upToCount: tailBytes) ?? Data())
        }
        return Data(hasher.finalize())
        #else
        var hasher = Hasher()

        if fileSize > 0 {
            let head = try handle.read(upToCount: headBytes) ?? Data()
            hasher.update(head)
        }

        if fileSize > Int64(headBytes + tailBytes) {
            try handle.seek(toOffset: UInt64(max(0, fileSize - Int64(tailBytes))))
            let tail = try handle.read(upToCount: tailBytes) ?? Data()
            hasher.update(tail)
        }

        return hasher.finalize()
        #endif
    }

    public struct Hasher {
        private var state: [UInt32] = [
            0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
            0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
        ]
        private var buffer: [UInt8] = []
        private var length: UInt64 = 0

        public init() { buffer.reserveCapacity(64) }

        public mutating func update<C: Collection>(_ bytes: C) where C.Element == UInt8 {
            length &+= UInt64(bytes.count)
            var iterator = bytes.makeIterator()
            while let b = iterator.next() {
                buffer.append(b)
                if buffer.count == 64 { compress() }
            }
        }

        public mutating func finalize() -> Data {
            let bitLength = length &* 8

            buffer.append(0x80)

            // Pad with zeros up to the 56th byte of a block, compressing any
            // block we fill on the way. Both loops have to check the boundary:
            // if the 0x80 landed on byte 64, or if padding runs past byte 64,
            // that block is complete and has to be compressed here or the
            // digest silently comes out wrong. Skipping either check breaks
            // every input whose length is 55, 56 or 63 modulo 64.
            if buffer.count % 64 == 0 {
                compress()
            }
            while buffer.count % 64 != 56 {
                buffer.append(0)
                if buffer.count % 64 == 0 {
                    compress()
                }
            }

            for shift in stride(from: 56, through: 0, by: -8) {
                buffer.append(UInt8((bitLength >> UInt64(shift)) & 0xff))
            }

            // The buffer is now exactly one 64-byte block.
            compress()

            var out = Data(capacity: 32)
            for word in state {
                out.append(UInt8((word >> 24) & 0xff))
                out.append(UInt8((word >> 16) & 0xff))
                out.append(UInt8((word >> 8) & 0xff))
                out.append(UInt8(word & 0xff))
            }
            return out
        }

        private mutating func compress() {
            var w = [UInt32](repeating: 0, count: 64)
            for i in 0..<16 {
                let o = i * 4
                w[i] = (UInt32(buffer[o]) << 24) | (UInt32(buffer[o + 1]) << 16)
                    | (UInt32(buffer[o + 2]) << 8) | UInt32(buffer[o + 3])
            }
            for i in 16..<64 {
                let s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
                let s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
                w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
            }

            var a = state[0], b = state[1], c = state[2], d = state[3]
            var e = state[4], f = state[5], g = state[6], h = state[7]

            for i in 0..<64 {
                let s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
                let ch = (e & f) ^ (~e & g)
                let temp1 = h &+ s1 &+ ch &+ k[i] &+ w[i]
                let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
                let maj = (a & b) ^ (a & c) ^ (b & c)
                let temp2 = s0 &+ maj

                h = g; g = f; f = e
                e = d &+ temp1
                d = c; c = b; b = a
                a = temp1 &+ temp2
            }

            state[0] = state[0] &+ a; state[1] = state[1] &+ b
            state[2] = state[2] &+ c; state[3] = state[3] &+ d
            state[4] = state[4] &+ e; state[5] = state[5] &+ f
            state[6] = state[6] &+ g; state[7] = state[7] &+ h
            buffer.removeAll(keepingCapacity: true)
        }

        private func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32 - n)) }
    }
}
