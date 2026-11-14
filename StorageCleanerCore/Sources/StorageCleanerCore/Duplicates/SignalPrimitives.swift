import Foundation

/// 64-bit difference hash ("dHash") used for video keyframes.
public enum PerceptualHash {
    public static let width = 9
    public static let height = 8

    /// `luminance` is a row-major 9×8 grayscale image (72 values). Each bit records whether a pixel
    /// is brighter than its right-hand neighbour.
    public static func dHash(luminance: [UInt8]) -> UInt64? {
        guard luminance.count == width * height else { return nil }
        var hash: UInt64 = 0
        for row in 0..<height {
            for col in 0..<(width - 1) {
                hash <<= 1
                if luminance[row * width + col] > luminance[row * width + col + 1] { hash |= 1 }
            }
        }
        return hash
    }

    public static func hammingDistance(_ a: UInt64, _ b: UInt64) -> Int {
        (a ^ b).nonzeroBitCount
    }
}

/// A coarse loudness curve used to compare audio recordings without decoding them twice.
public enum AudioEnvelope {
    /// Root-mean-square level per window of mono samples.
    public static func make(samples: [Float], sampleRate: Double, windowDuration: Double = 0.5) -> [Float] {
        let window = max(1, Int(sampleRate * windowDuration))
        guard !samples.isEmpty else { return [] }
        return stride(from: 0, to: samples.count, by: window).map { start in
            let slice = samples[start..<min(start + window, samples.count)]
            let sumOfSquares = slice.reduce(Float(0)) { $0 + $1 * $1 }
            return (sumOfSquares / Float(slice.count)).squareRoot()
        }
    }

    /// Best Pearson correlation between the two curves over small time shifts, in -1...1.
    /// Flat curves (silence) carry no shape, so they never match.
    public static func similarity(_ a: [Float], _ b: [Float], maxLag: Int = 2, minimumOverlap: Int = 4) -> Double {
        var best = -1.0
        for lag in -maxLag...maxLag {
            let aStart = max(0, lag), bStart = max(0, -lag)
            let overlap = min(a.count - aStart, b.count - bStart)
            guard overlap >= minimumOverlap else { continue }
            if let r = pearson(a[aStart..<aStart + overlap], b[bStart..<bStart + overlap]) {
                best = max(best, r)
            }
        }
        return best
    }

    private static func pearson(_ x: ArraySlice<Float>, _ y: ArraySlice<Float>) -> Double? {
        let n = Double(x.count)
        let meanX = x.reduce(0.0) { $0 + Double($1) } / n
        let meanY = y.reduce(0.0) { $0 + Double($1) } / n
        var covariance = 0.0, varianceX = 0.0, varianceY = 0.0
        for (xi, yi) in zip(x, y) {
            let dx = Double(xi) - meanX, dy = Double(yi) - meanY
            covariance += dx * dy
            varianceX += dx * dx
            varianceY += dy * dy
        }
        guard varianceX > 1e-12, varianceY > 1e-12 else { return nil }
        return covariance / (varianceX * varianceY).squareRoot()
    }
}

public enum FeatureVector {
    /// Euclidean distance, the metric Vision uses for image feature prints. `nil` when lengths differ.
    public static func distance(_ a: [Float], _ b: [Float]) -> Float? {
        guard a.count == b.count, !a.isEmpty else { return nil }
        var sum: Float = 0
        for i in a.indices {
            let d = a[i] - b[i]
            sum += d * d
        }
        return sum.squareRoot()
    }
}

/// Compact little-endian storage for signature vectors.
public enum BinaryPacking {
    public static func data(from floats: [Float]) -> Data {
        var data = Data(capacity: floats.count * 4)
        for value in floats {
            withUnsafeBytes(of: value.bitPattern.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    public static func floats(from data: Data) -> [Float] {
        let bytes = [UInt8](data)
        return stride(from: 0, to: bytes.count - bytes.count % 4, by: 4).map { i -> Float in
            var bits: UInt32 = 0
            for b in 0..<4 { bits |= UInt32(bytes[i + b]) << UInt32(b * 8) }
            return Float(bitPattern: bits)
        }
    }

    public static func data(from values: [UInt64]) -> Data {
        var data = Data(capacity: values.count * 8)
        for value in values {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    public static func uint64s(from data: Data) -> [UInt64] {
        let bytes = [UInt8](data)
        return stride(from: 0, to: bytes.count - bytes.count % 8, by: 8).map { i in
            (0..<8).reduce(UInt64(0)) { $0 | UInt64(bytes[i + $1]) << UInt64($1 * 8) }
        }
    }
}
