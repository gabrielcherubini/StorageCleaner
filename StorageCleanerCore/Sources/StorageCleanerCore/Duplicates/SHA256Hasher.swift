import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

/// Incremental SHA-256. Uses CryptoKit on Apple platforms and a portable implementation elsewhere.
public struct SHA256Hasher {
    #if canImport(CryptoKit)
    private var impl = CryptoKit.SHA256()
    #else
    private var impl = PortableSHA256()
    #endif

    public init() {}

    public mutating func update(_ data: Data) {
        data.withUnsafeBytes { update(bytes: $0) }
    }

    public mutating func update(bytes: UnsafeRawBufferPointer) {
        #if canImport(CryptoKit)
        impl.update(bufferPointer: bytes)
        #else
        impl.update(bytes: bytes)
        #endif
    }

    /// Lowercase hex digest.
    public mutating func finalize() -> String {
        #if canImport(CryptoKit)
        return impl.finalize().map { String(format: "%02x", $0) }.joined()
        #else
        return impl.finalize().hexString
        #endif
    }

    public static func hash(_ data: Data) -> String {
        var hasher = SHA256Hasher()
        hasher.update(data)
        return hasher.finalize()
    }
}

/// FIPS 180-4 SHA-256 in plain Swift, for platforms without CryptoKit.
struct PortableSHA256 {
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

    private var state: [UInt32] = [
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
    ]
    private var pending: [UInt8] = []
    private var messageLength: UInt64 = 0
    private var w = [UInt32](repeating: 0, count: 64)

    init() {
        pending.reserveCapacity(64)
    }

    mutating func update(_ data: Data) {
        data.withUnsafeBytes { update(bytes: $0) }
    }

    mutating func update(bytes: UnsafeRawBufferPointer) {
        messageLength &+= UInt64(bytes.count)
        var offset = 0
        if !pending.isEmpty {
            let take = min(64 - pending.count, bytes.count)
            pending.append(contentsOf: bytes[0..<take])
            offset = take
            guard pending.count == 64 else { return }
            let block = pending
            block.withUnsafeBytes { process(block: $0) }
            pending.removeAll(keepingCapacity: true)
        }
        while bytes.count - offset >= 64 {
            process(block: UnsafeRawBufferPointer(rebasing: bytes[offset..<offset + 64]))
            offset += 64
        }
        if offset < bytes.count {
            pending.append(contentsOf: bytes[offset...])
        }
    }

    mutating func finalize() -> [UInt8] {
        var tail = pending
        tail.append(0x80)
        while tail.count % 64 != 56 { tail.append(0) }
        let bitLength = messageLength &* 8
        for shift in stride(from: 56, through: 0, by: -8) {
            tail.append(UInt8(truncatingIfNeeded: bitLength >> UInt64(shift)))
        }
        tail.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                process(block: UnsafeRawBufferPointer(rebasing: raw[offset..<offset + 64]))
                offset += 64
            }
        }
        pending.removeAll()
        return state.flatMap { word in
            [UInt8(word >> 24), UInt8(truncatingIfNeeded: word >> 16), UInt8(truncatingIfNeeded: word >> 8), UInt8(truncatingIfNeeded: word)]
        }
    }

    private mutating func process(block: UnsafeRawBufferPointer) {
        for i in 0..<16 {
            w[i] = UInt32(block[i * 4]) << 24 | UInt32(block[i * 4 + 1]) << 16
                | UInt32(block[i * 4 + 2]) << 8 | UInt32(block[i * 4 + 3])
        }
        for i in 16..<64 {
            let s0 = w[i - 15].rotr(7) ^ w[i - 15].rotr(18) ^ (w[i - 15] >> 3)
            let s1 = w[i - 2].rotr(17) ^ w[i - 2].rotr(19) ^ (w[i - 2] >> 10)
            w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
        }

        var a = state[0], b = state[1], c = state[2], d = state[3]
        var e = state[4], f = state[5], g = state[6], h = state[7]
        for i in 0..<64 {
            let s1 = e.rotr(6) ^ e.rotr(11) ^ e.rotr(25)
            let ch = (e & f) ^ (~e & g)
            let t1 = h &+ s1 &+ ch &+ Self.k[i] &+ w[i]
            let s0 = a.rotr(2) ^ a.rotr(13) ^ a.rotr(22)
            let maj = (a & b) ^ (a & c) ^ (b & c)
            let t2 = s0 &+ maj
            h = g; g = f; f = e; e = d &+ t1
            d = c; c = b; b = a; a = t1 &+ t2
        }
        state[0] &+= a; state[1] &+= b; state[2] &+= c; state[3] &+= d
        state[4] &+= e; state[5] &+= f; state[6] &+= g; state[7] &+= h
    }
}

private extension UInt32 {
    func rotr(_ n: UInt32) -> UInt32 { (self >> n) | (self << (32 - n)) }
}

extension Array where Element == UInt8 {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
