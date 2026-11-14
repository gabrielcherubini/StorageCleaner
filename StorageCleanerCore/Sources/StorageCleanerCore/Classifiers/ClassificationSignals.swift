import Foundation

/// Pixel statistics of a small grayscale rendition of a photo or video frame.
public struct ImageStats: Codable, Hashable, Sendable {
    /// 0...255
    public var meanLuminance: Double
    public var standardDeviation: Double
    /// Share of pixels darker than 16 / brighter than 240.
    public var darkFraction: Double
    public var brightFraction: Double
    /// Variance of the 4-neighbour Laplacian; low values mean a blurry image.
    public var laplacianVariance: Double
    /// Share of pixels on a strong edge.
    public var edgeDensity: Double

    public init(meanLuminance: Double, standardDeviation: Double, darkFraction: Double, brightFraction: Double,
                laplacianVariance: Double, edgeDensity: Double) {
        self.meanLuminance = meanLuminance
        self.standardDeviation = standardDeviation
        self.darkFraction = darkFraction
        self.brightFraction = brightFraction
        self.laplacianVariance = laplacianVariance
        self.edgeDensity = edgeDensity
    }
}

public enum ImageStatistics {
    public static let darkLevel: UInt8 = 16
    public static let brightLevel: UInt8 = 240
    public static let edgeThreshold = 32

    /// `luminance` is row-major 8-bit grayscale. Returns `nil` for images smaller than 3×3.
    public static func compute(luminance: [UInt8], width: Int, height: Int) -> ImageStats? {
        guard width >= 3, height >= 3, luminance.count == width * height else { return nil }
        let count = Double(luminance.count)

        var sum = 0.0, sumOfSquares = 0.0, dark = 0, bright = 0
        for value in luminance {
            let v = Double(value)
            sum += v
            sumOfSquares += v * v
            if value < darkLevel { dark += 1 }
            if value > brightLevel { bright += 1 }
        }
        let mean = sum / count
        let deviation = max(0, sumOfSquares / count - mean * mean).squareRoot()

        var lapSum = 0.0, lapSumOfSquares = 0.0, edges = 0
        let interior = Double((width - 2) * (height - 2))
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let i = y * width + x
                let center = Int(luminance[i])
                let left = Int(luminance[i - 1]), right = Int(luminance[i + 1])
                let up = Int(luminance[i - width]), down = Int(luminance[i + width])
                let laplacian = Double(left + right + up + down - 4 * center)
                lapSum += laplacian
                lapSumOfSquares += laplacian * laplacian
                if abs(right - left) + abs(down - up) > edgeThreshold * 2 { edges += 1 }
            }
        }
        let lapMean = lapSum / interior
        return ImageStats(
            meanLuminance: mean,
            standardDeviation: deviation,
            darkFraction: Double(dark) / count,
            brightFraction: Double(bright) / count,
            laplacianVariance: max(0, lapSumOfSquares / interior - lapMean * lapMean),
            edgeDensity: Double(edges) / interior
        )
    }
}

/// Classifier inputs read from an item's data, cached with its other signatures.
public struct ClassificationSignals: Codable, Hashable, Sendable {
    /// Whether the image carries camera make/model metadata. Apps that forward media strip it.
    public var hasCameraMetadata: Bool?
    public var imageStats: ImageStats?
    /// Vision document-segmentation confidence; 0 when no document was found.
    public var documentConfidence: Double?
    /// Recognized text, only read for likely documents.
    public var recognizedText: String?
    /// Mean Hamming distance between consecutive keyframe hashes (videos).
    public var motion: Double?
    /// Loudest window of the audio loudness curve, 0...1.
    public var peakLevel: Double?

    public init() {}
}

extension MediaSignatures {
    public var classificationSignals: ClassificationSignals {
        get { classification ?? ClassificationSignals() }
        set { classification = newValue }
    }
}
