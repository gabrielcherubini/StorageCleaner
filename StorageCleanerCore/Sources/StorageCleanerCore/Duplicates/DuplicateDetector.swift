import Foundation

public struct DuplicateOptions: Equatable, Sendable {
    /// Maximum Vision feature-print distance for two photos to count as near duplicates.
    public var photoDistanceThreshold: Float = 0.4
    /// Only photos taken within this interval of each other are compared.
    public var photoTimeWindow: TimeInterval = 15 * 60
    /// Videos are compared only when their durations differ by at most the larger of these.
    public var videoDurationTolerance: TimeInterval = 1
    public var videoDurationRelativeTolerance: Double = 0.02
    /// Maximum mean Hamming distance (out of 64 bits) between matching keyframe hashes.
    public var videoFrameHashThreshold: Double = 10
    public var audioDurationTolerance: TimeInterval = 1
    /// Minimum loudness-curve correlation for two recordings to match.
    public var audioSimilarityThreshold: Double = 0.95
    public var audioMaxLag = 2

    public static let `default` = DuplicateOptions()

    public init() {}
}

/// Which signatures still have to be read before `DuplicateDetector.detect` can run.
public struct SignatureNeeds: Equatable, Sendable {
    /// Files missing duration (and so not yet comparable); read these first, then ask again.
    public var metadata: [MediaItem] = []
    public var sha256: [MediaItem] = []
    public var featurePrint: [MediaItem] = []
    public var frameHashes: [MediaItem] = []
    public var audioEnvelope: [MediaItem] = []
    /// Items that would need analysis but are only in iCloud while downloads are not allowed.
    public var skippedCloudOnly: [MediaItem] = []

    public var isEmpty: Bool {
        metadata.isEmpty && sha256.isEmpty && featurePrint.isEmpty && frameHashes.isEmpty && audioEnvelope.isEmpty
    }
}

public enum DuplicateDetector {
    /// Whether analysis may read the item's data. Placeholder stubs never contain the data;
    /// iCloud-only items may be read only when the user allowed downloads.
    public static func canRead(_ item: MediaItem, allowDownloads: Bool) -> Bool {
        if item.hints.contains(.iCloudPlaceholder) { return false }
        if item.isLocallyAvailable == false { return allowDownloads }
        return true
    }

    public static func signatureNeeds(
        items: [MediaItem],
        signatures: [String: MediaSignatures],
        allowDownloads: Bool,
        options: DuplicateOptions = .default
    ) -> SignatureNeeds {
        let valid = validSignatures(items: items, signatures: signatures)
        let enrichedItems = items.map { enriched($0, valid[$0.location.indexKey]) }
        var needs = SignatureNeeds()
        var skipped: [String: MediaItem] = [:]

        func need(_ item: MediaItem, missing: (MediaSignatures) -> Bool, into list: inout [MediaItem]) {
            let key = item.location.indexKey
            guard valid[key].map(missing) ?? true else { return }
            if canRead(item, allowDownloads: allowDownloads) {
                list.append(item)
            } else {
                skipped[key] = item
            }
        }

        for item in enrichedItems where item.kind != .photo && item.duration == nil {
            if case .file = item.location {
                need(item, missing: { $0.duration == nil }, into: &needs.metadata)
            }
        }

        for bucket in sizeBuckets(enrichedItems) {
            for item in bucket { need(item, missing: { $0.sha256 == nil }, into: &needs.sha256) }
        }

        let photos = enrichedItems.filter { $0.kind == .photo }
        for index in itemsWithNeighbors(photos, value: { $0.creationDate?.timeIntervalSinceReferenceDate },
                                        tolerance: { _ in options.photoTimeWindow }) {
            need(photos[index], missing: { $0.featurePrint == nil }, into: &needs.featurePrint)
        }

        let videos = enrichedItems.filter { $0.kind == .video }
        for index in itemsWithNeighbors(videos, value: \.duration,
                                        tolerance: { videoTolerance($0, options) }) {
            need(videos[index], missing: { $0.frameHashes == nil }, into: &needs.frameHashes)
        }

        let audio = enrichedItems.filter { $0.kind == .audio }
        for index in itemsWithNeighbors(audio, value: \.duration, tolerance: { _ in options.audioDurationTolerance }) {
            need(audio[index], missing: { $0.audioEnvelope == nil }, into: &needs.audioEnvelope)
        }

        needs.skippedCloudOnly = skipped.values.sortedBySizeDescending()
        return needs
    }

    /// Groups exact copies first; near-duplicate grouping then runs on what is left plus each exact
    /// group's keeper, so every item appears in at most one group. Heaviest savings first.
    public static func detect(
        items: [MediaItem],
        signatures: [String: MediaSignatures],
        options: DuplicateOptions = .default
    ) -> [DuplicateGroup] {
        let valid = validSignatures(items: items, signatures: signatures)
        let enrichedItems = items.map { enriched($0, valid[$0.location.indexKey]) }
        func signature(_ item: MediaItem) -> MediaSignatures? { valid[item.location.indexKey] }

        var groups: [DuplicateGroup] = []
        for bucket in sizeBuckets(enrichedItems) {
            let byHash = Dictionary(grouping: bucket.filter { signature($0)?.sha256 != nil }) { signature($0)!.sha256! }
            for copies in byHash.values {
                if let group = DuplicateGroup(match: .exact, items: copies, similarity: 1) { groups.append(group) }
            }
        }

        let absorbed = Set(groups.flatMap { $0.items.dropFirst().map(\.location) })
        let remaining = enrichedItems.filter { !absorbed.contains($0.location) }

        // Photos: feature prints of the same revision, compared within a time window.
        let photos = remaining.filter { $0.kind == .photo && signature($0)?.featurePrint != nil }
        for revisionGroup in Dictionary(grouping: photos, by: { signature($0)?.featurePrintRevision ?? 0 }).values {
            let prints = revisionGroup.map { signature($0)!.featurePrint! }
            groups += nearGroups(
                revisionGroup, match: .similarPhoto,
                value: { $0.creationDate?.timeIntervalSinceReferenceDate },
                tolerance: { _ in options.photoTimeWindow },
                threshold: Double(options.photoDistanceThreshold),
                distance: { i, j in FeatureVector.distance(prints[i], prints[j]).map(Double.init) }
            )
        }

        let videos = remaining.filter { $0.kind == .video && !(signature($0)?.frameHashes?.isEmpty ?? true) }
        let frameHashes = videos.map { signature($0)!.frameHashes! }
        groups += nearGroups(
            videos, match: .similarVideo,
            value: \.duration,
            tolerance: { videoTolerance($0, options) },
            threshold: options.videoFrameHashThreshold,
            distance: { i, j in
                let a = frameHashes[i], b = frameHashes[j]
                guard a.count == b.count else { return nil }
                return Double(zip(a, b).map { PerceptualHash.hammingDistance($0, $1) }.reduce(0, +)) / Double(a.count)
            }
        )

        let audio = remaining.filter { $0.kind == .audio && !(signature($0)?.audioEnvelope?.isEmpty ?? true) }
        let envelopes = audio.map { signature($0)!.audioEnvelope! }
        groups += nearGroups(
            audio, match: .similarAudio,
            value: \.duration,
            tolerance: { _ in options.audioDurationTolerance },
            threshold: 1 - options.audioSimilarityThreshold,
            distance: { i, j in 1 - AudioEnvelope.similarity(envelopes[i], envelopes[j], maxLag: options.audioMaxLag) }
        )

        return groups.sorted {
            if $0.reclaimableBytes != $1.reclaimableBytes { return $0.reclaimableBytes > $1.reclaimableBytes }
            return $0.id < $1.id
        }
    }

    // MARK: Helpers

    static func validSignatures(items: [MediaItem], signatures: [String: MediaSignatures]) -> [String: MediaSignatures] {
        var valid: [String: MediaSignatures] = [:]
        for item in items {
            let key = item.location.indexKey
            if let signature = signatures[key], signature.isValid(for: item) { valid[key] = signature }
        }
        return valid
    }

    /// Fills metadata the scan could not read (for files) from analysis results.
    static func enriched(_ item: MediaItem, _ signature: MediaSignatures?) -> MediaItem {
        guard let signature else { return item }
        var item = item
        if item.duration == nil { item.duration = signature.duration }
        if item.pixelWidth == nil || item.pixelHeight == nil {
            item.pixelWidth = signature.pixelWidth
            item.pixelHeight = signature.pixelHeight
        }
        return item
    }

    /// Items sharing kind and exact byte size with at least one other item: the only ones worth hashing.
    static func sizeBuckets(_ items: [MediaItem]) -> [[MediaItem]] {
        struct BucketKey: Hashable { let kind: MediaKind; let size: Int64 }
        return Dictionary(grouping: items.filter { $0.byteSize > 0 }) { BucketKey(kind: $0.kind, size: $0.byteSize) }
            .values.filter { $0.count >= 2 }
            .sorted { $0[0].byteSize > $1[0].byteSize }
    }

    private static func videoTolerance(_ duration: Double, _ options: DuplicateOptions) -> Double {
        max(options.videoDurationTolerance, duration * options.videoDurationRelativeTolerance)
    }

    /// Index pairs `(i, j)` whose values are within tolerance, found with a sliding window over the
    /// values in sorted order. Items without a value are never paired.
    static func candidatePairs(
        _ items: [MediaItem],
        value: (MediaItem) -> Double?,
        tolerance: (Double) -> Double
    ) -> [(Int, Int)] {
        let sorted = items.indices.compactMap { i in value(items[i]).map { (i, $0) } }.sorted { $0.1 < $1.1 }
        var pairs: [(Int, Int)] = []
        for a in sorted.indices {
            let (i, v) = sorted[a]
            let limit = v + tolerance(v)
            var b = a + 1
            while b < sorted.count, sorted[b].1 <= limit {
                pairs.append((i, sorted[b].0))
                b += 1
            }
        }
        return pairs
    }

    private static func itemsWithNeighbors(
        _ items: [MediaItem],
        value: (MediaItem) -> Double?,
        tolerance: (Double) -> Double
    ) -> [Int] {
        var indices = Set<Int>()
        for (i, j) in candidatePairs(items, value: value, tolerance: tolerance) {
            indices.insert(i)
            indices.insert(j)
        }
        return indices.sorted()
    }

    private static func nearGroups(
        _ items: [MediaItem],
        match: DuplicateGroup.Match,
        value: (MediaItem) -> Double?,
        tolerance: (Double) -> Double,
        threshold: Double,
        distance: (Int, Int) -> Double?
    ) -> [DuplicateGroup] {
        let pairs = candidatePairs(items, value: value, tolerance: tolerance).compactMap { i, j -> (Int, Int, Double)? in
            guard let d = distance(i, j), d <= threshold else { return nil }
            return (i, j, d)
        }
        return cluster(count: items.count, pairs: pairs, threshold: threshold, distance: distance).compactMap { members, maxDistance in
            let similarity = threshold > 0 ? 1 - 0.5 * (maxDistance / threshold) : 1
            return DuplicateGroup(match: match, items: members.map { items[$0] }, similarity: similarity)
        }
    }

    /// Complete-linkage clustering: two clusters merge only if every cross pair is within the
    /// threshold, which stops long bursts of slowly changing shots from chaining into one group.
    static func cluster(
        count: Int,
        pairs: [(Int, Int, Double)],
        threshold: Double,
        distance: (Int, Int) -> Double?
    ) -> [(members: [Int], maxDistance: Double)] {
        var clusterOf = Array(0..<count)
        var members: [Int: [Int]] = [:]
        var maxDistance: [Int: Double] = [:]
        for i in 0..<count { members[i] = [i] }

        for (i, j, d) in pairs.sorted(by: { $0.2 < $1.2 }) {
            let ci = clusterOf[i], cj = clusterOf[j]
            guard ci != cj, let a = members[ci], let b = members[cj] else { continue }
            var worst = max(d, maxDistance[ci] ?? 0, maxDistance[cj] ?? 0)
            var compatible = true
            outer: for x in a {
                for y in b {
                    guard let dxy = (x == i && y == j) ? d : distance(x, y), dxy <= threshold else {
                        compatible = false
                        break outer
                    }
                    worst = max(worst, dxy)
                }
            }
            guard compatible else { continue }
            members[ci] = a + b
            members[cj] = nil
            maxDistance[ci] = worst
            for y in b { clusterOf[y] = ci }
        }

        return members.values.filter { $0.count >= 2 }.map { ($0.sorted(), maxDistance[clusterOf[$0[0]]] ?? 0) }
            .sorted { $0.members[0] < $1.members[0] }
    }
}
