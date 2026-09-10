import Foundation

/// SHA-256, in Swift, because two of six's four fronts have nothing else.
///
/// Every model Bergamot loads arrives over the network as a few tens of megabytes that are then
/// handed straight to a wasm heap and executed as weights. Mozilla's Remote Settings publishes the
/// digest of each attachment beside it, so checking is free and not checking is the one way a
/// truncated download becomes a crash inside a 5 MB binary — or worse, a cache poisoned once and
/// re-read every launch afterwards.
///
/// `CryptoKit` answers this on Apple and does not exist on Linux or Windows; `swift-crypto` would,
/// at the cost of a fifth package in a dependency graph that CLAUDE.md spends a chapter on keeping
/// still. Sixty lines of FIPS 180-4 is the cheaper trade, and it is the rare piece of code where
/// "does it work" has a published answer: `ChecksumTests` runs the standard vectors.
nonisolated enum Checksum {
    /// The first thirty-two bits of the fractional parts of the cube roots of the first sixty-four
    /// primes — the round constants, as the standard gives them.
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

    /// The digest as lowercase hex, which is how Remote Settings writes it.
    static func sha256(_ data: Data) -> String {
        var state = State()
        state.update(data)
        return state.finish()
    }

    /// The same, without ever holding the file in memory.
    ///
    /// A model is 30 MB and the wasm is 5, and this runs on the machine that just downloaded both;
    /// reading them whole to hash them would double the peak for no reason. One megabyte at a time
    /// is small enough to be invisible and large enough that the read is not the cost.
    static func sha256(ofFileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var state = State()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            state.update(chunk)
        }
        return state.finish()
    }

    /// The running hash. A value type: nothing here is shared and nothing is a class.
    private struct State {
        /// The fractional parts of the square roots of the first eight primes.
        private var h: [UInt32] = [
            0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
            0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
        ]
        /// What is left over from the last update: the standard works in 64-byte blocks and a
        /// caller's chunks land wherever they land.
        private var tail = [UInt8]()
        private var length: UInt64 = 0

        mutating func update(_ data: Data) {
            length &+= UInt64(data.count) &* 8
            tail.append(contentsOf: data)
            var offset = 0
            while tail.count - offset >= 64 {
                compress(Array(tail[offset..<(offset + 64)]))
                offset += 64
            }
            if offset > 0 { tail.removeFirst(offset) }
        }

        mutating func finish() -> String {
            // The padding the standard prescribes: a one bit, zeroes, and the length in bits as a
            // big-endian 64-bit number, all of it landing on a block boundary.
            var block = tail
            block.append(0x80)
            while block.count % 64 != 56 { block.append(0) }
            for shift in stride(from: 56, through: 0, by: -8) {
                block.append(UInt8((length >> UInt64(shift)) & 0xff))
            }
            for start in stride(from: 0, to: block.count, by: 64) {
                compress(Array(block[start..<(start + 64)]))
            }
            return h.map { word in
                String(format: "%08x", word)
            }.joined()
        }

        private mutating func compress(_ block: [UInt8]) {
            var w = [UInt32](repeating: 0, count: 64)
            for index in 0..<16 {
                let base = index * 4
                w[index] = UInt32(block[base]) << 24 | UInt32(block[base + 1]) << 16
                    | UInt32(block[base + 2]) << 8 | UInt32(block[base + 3])
            }
            for index in 16..<64 {
                let s0 = rotate(w[index - 15], 7) ^ rotate(w[index - 15], 18) ^ (w[index - 15] >> 3)
                let s1 = rotate(w[index - 2], 17) ^ rotate(w[index - 2], 19) ^ (w[index - 2] >> 10)
                w[index] = w[index - 16] &+ s0 &+ w[index - 7] &+ s1
            }

            var (a, b, c, d) = (h[0], h[1], h[2], h[3])
            var (e, f, g, hh) = (h[4], h[5], h[6], h[7])
            for index in 0..<64 {
                let s1 = rotate(e, 6) ^ rotate(e, 11) ^ rotate(e, 25)
                let choice = (e & f) ^ (~e & g)
                let temp1 = hh &+ s1 &+ choice &+ k[index] &+ w[index]
                let s0 = rotate(a, 2) ^ rotate(a, 13) ^ rotate(a, 22)
                let majority = (a & b) ^ (a & c) ^ (b & c)
                let temp2 = s0 &+ majority
                hh = g; g = f; f = e
                e = d &+ temp1
                d = c; c = b; b = a
                a = temp1 &+ temp2
            }
            h[0] &+= a; h[1] &+= b; h[2] &+= c; h[3] &+= d
            h[4] &+= e; h[5] &+= f; h[6] &+= g; h[7] &+= hh
        }

        private func rotate(_ value: UInt32, _ places: UInt32) -> UInt32 {
            (value >> places) | (value << (32 - places))
        }
    }
}
