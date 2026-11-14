import Foundation
import XCTest
@testable import StorageCleanerCore

final class SignalPrimitivesTests: XCTestCase {
    private let vectors: [(String, String)] = [
        ("", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"),
        ("abc", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"),
        ("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq",
         "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"),
    ]

    func testSHA256KnownVectors() {
        for (input, expected) in vectors {
            XCTAssertEqual(SHA256Hasher.hash(Data(input.utf8)), expected, input)
            var portable = PortableSHA256()
            portable.update(Data(input.utf8))
            XCTAssertEqual(portable.finalize().hexString, expected, input)
        }
    }

    func testSHA256MillionAs() {
        let data = Data(repeating: UInt8(ascii: "a"), count: 1_000_000)
        let expected = "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0"
        XCTAssertEqual(SHA256Hasher.hash(data), expected)
        var portable = PortableSHA256()
        portable.update(data)
        XCTAssertEqual(portable.finalize().hexString, expected)
    }

    func testSHA256ChunkedMatchesOneShot() {
        let data = Data((0..<10_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        var hasher = SHA256Hasher()
        var portable = PortableSHA256()
        var offset = 0
        for size in [1, 63, 64, 65, 127, 500, 3_000] where offset < data.count {
            let chunk = data[offset..<min(offset + size, data.count)]
            hasher.update(Data(chunk))
            portable.update(Data(chunk))
            offset += size
        }
        hasher.update(data[offset...])
        portable.update(Data(data[offset...]))
        XCTAssertEqual(hasher.finalize(), SHA256Hasher.hash(data))
        XCTAssertEqual(portable.finalize().hexString, SHA256Hasher.hash(data))
    }

    func testDHash() {
        let gradient = (0..<72).map { UInt8(255 - ($0 % 9) * 20) }
        XCTAssertEqual(PerceptualHash.dHash(luminance: gradient), UInt64.max)
        let flat = [UInt8](repeating: 100, count: 72)
        XCTAssertEqual(PerceptualHash.dHash(luminance: flat), 0)
        XCTAssertNil(PerceptualHash.dHash(luminance: [1, 2, 3]))
        XCTAssertEqual(PerceptualHash.hammingDistance(0b1011, 0b0001), 2)
    }

    func testAudioEnvelopeAndSimilarity() {
        let rate = 100.0
        let tone = (0..<1_000).map { i -> Float in
            let loudness: Float = (i / 100) % 3 == 0 ? 0.9 : 0.2
            return loudness * (i % 2 == 0 ? 1 : -1)
        }
        let envelope = AudioEnvelope.make(samples: tone, sampleRate: rate, windowDuration: 0.5)
        XCTAssertEqual(envelope.count, 20)
        XCTAssertEqual(envelope[0], 0.9, accuracy: 0.001)

        let quieter = envelope.map { $0 * 0.5 }
        XCTAssertGreaterThan(AudioEnvelope.similarity(envelope, quieter), 0.99)

        let shifted = Array(envelope.dropFirst(1))
        XCTAssertGreaterThan(AudioEnvelope.similarity(envelope, shifted, maxLag: 2), 0.99)

        let different = envelope.reversed().map { 1 - $0 }
        XCTAssertLessThan(AudioEnvelope.similarity(envelope, Array(different)), 0.9)

        let silence = [Float](repeating: 0, count: 20)
        XCTAssertLessThan(AudioEnvelope.similarity(silence, silence), 0)
    }

    func testFeatureVectorDistance() {
        XCTAssertEqual(FeatureVector.distance([0, 0], [3, 4]), 5)
        XCTAssertNil(FeatureVector.distance([1], [1, 2]))
    }

    func testBinaryPackingRoundTrip() {
        let floats: [Float] = [0, -1.5, .pi, 1e-7, .greatestFiniteMagnitude]
        XCTAssertEqual(BinaryPacking.floats(from: BinaryPacking.data(from: floats)), floats)
        let hashes: [UInt64] = [0, 1, .max, 0x0123_4567_89AB_CDEF]
        XCTAssertEqual(BinaryPacking.uint64s(from: BinaryPacking.data(from: hashes)), hashes)
        XCTAssertEqual(BinaryPacking.data(from: [UInt64(1)]), Data([1, 0, 0, 0, 0, 0, 0, 0]))
    }
}
