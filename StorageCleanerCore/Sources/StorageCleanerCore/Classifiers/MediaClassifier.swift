import Foundation

public enum ClassificationReason: String, Codable, Sendable, CaseIterable {
    // Chat and app forwards
    case messagingFilename
    case noCameraMetadata
    case messagingResolution
    case rapidSaveBurst
    // Screenshots and screen recordings
    case screenshotFlag
    case screenRecordingFlag
    case screenshotFilename
    case screenSize
    // Receipts and documents
    case documentDetected
    case receiptKeywords
    case moneyAmount
    case taxID
    // Low quality
    case blurry
    case tooDark
    case overexposed
    case lowDetail
    case shortVideo
    case lowMotion
    case shortAudio
    case nearSilent
}

public struct Classification: Hashable, Codable, Sendable {
    public let category: CleanupCategory
    /// How sure the classifier is that the item belongs in `category`, 0...1.
    public let confidence: Double
    public let reasons: [ClassificationReason]

    public init(category: CleanupCategory, confidence: Double, reasons: [ClassificationReason]) {
        self.category = category
        self.confidence = min(1, max(0, confidence))
        self.reasons = reasons
    }
}

public struct ClassifierOptions: Equatable, Sendable {
    /// Classifications below this confidence are dropped.
    public var minimumConfidence = 0.35
    /// Confidence needed for "Likely to delete"; anything lower is "Likely to keep".
    public var deleteThresholds: [CleanupCategory: Double] = [
        .chatForwards: 0.7, .screenshots: 0.8, .receipts: 0.85, .lowQuality: 0.7,
    ]
    public var shortVideoDuration: TimeInterval = 3
    public var shortAudioDuration: TimeInterval = 3
    /// Videos up to this long get keyframe and exposure analysis.
    public var videoAnalysisMaxDuration: TimeInterval = 5
    /// Audio up to this long gets a loudness check.
    public var audioAnalysisMaxDuration: TimeInterval = 10
    public var burstWindow: TimeInterval = 10
    public var documentTextThreshold = 0.5
    /// Paper-like photos (bright with high-contrast detail, as text on a page) also get text
    /// recognition, so receipts photographed without a visible edge are not missed.
    public var paperMinimumMeanLuminance = 170.0
    public var paperMinimumDeviation = 30.0
    public var paperEdgeDensity: ClosedRange<Double> = 0.02...0.4

    public static let `default` = ClassifierOptions()

    public init() {}

    public func deleteThreshold(for category: CleanupCategory) -> Double { deleteThresholds[category] ?? 0.8 }

    public func looksLikePaper(_ stats: ImageStats) -> Bool {
        stats.meanLuminance >= paperMinimumMeanLuminance
            && stats.standardDeviation >= paperMinimumDeviation
            && paperEdgeDensity.contains(stats.edgeDensity)
    }

    /// Whether text recognition should run: a detected document or a paper-like photo.
    public func wantsText(_ signals: ClassificationSignals) -> Bool {
        if let confidence = signals.documentConfidence, confidence >= documentTextThreshold { return true }
        return signals.imageStats.map(looksLikePaper) ?? false
    }
}

/// Which classifier signals still have to be read.
public struct ClassificationNeeds: Equatable, Sendable {
    /// Files missing duration; read these first, then ask again.
    public var metadata: [MediaItem] = []
    public var cameraMetadata: [MediaItem] = []
    /// Image statistics and document detection, from one small rendition.
    public var visual: [MediaItem] = []
    public var text: [MediaItem] = []
    public var videoFrames: [MediaItem] = []
    public var audioLevel: [MediaItem] = []
    public var skippedCloudOnly: [MediaItem] = []
}

public enum MediaClassifier {
    // MARK: What to read

    public static func needs(
        items: [MediaItem],
        signatures: [String: MediaSignatures],
        allowDownloads: Bool,
        options: ClassifierOptions = .default
    ) -> ClassificationNeeds {
        let valid = DuplicateDetector.validSignatures(items: items, signatures: signatures)
        var needs = ClassificationNeeds()
        var skipped: [String: MediaItem] = [:]

        func need(_ item: MediaItem, missing: (ClassificationSignals) -> Bool, into list: inout [MediaItem]) {
            let key = item.location.indexKey
            if let signals = valid[key]?.classification, !missing(signals) { return }
            if DuplicateDetector.canRead(item, allowDownloads: allowDownloads) {
                list.append(item)
            } else {
                skipped[key] = item
            }
        }

        for original in items {
            let key = original.location.indexKey
            let item = DuplicateDetector.enriched(original, valid[key])
            switch item.kind {
            case .photo:
                if isFlaggedScreenshot(item) { continue }
                if couldBeForward(item) { need(item, missing: { $0.hasCameraMetadata == nil }, into: &needs.cameraMetadata) }
                need(item, missing: { $0.imageStats == nil || $0.documentConfidence == nil }, into: &needs.visual)
                if let signals = valid[key]?.classification, signals.documentConfidence != nil, options.wantsText(signals) {
                    need(item, missing: { $0.recognizedText == nil }, into: &needs.text)
                }
            case .video:
                guard let duration = item.duration else {
                    if case .file = item.location, valid[key]?.duration == nil {
                        need(item, missing: { _ in true }, into: &needs.metadata)
                    }
                    continue
                }
                if duration <= options.videoAnalysisMaxDuration, !isFlaggedScreenshot(item) {
                    need(item, missing: { $0.motion == nil || $0.imageStats == nil }, into: &needs.videoFrames)
                }
            case .audio:
                guard let duration = item.duration else {
                    if case .file = item.location, valid[key]?.duration == nil {
                        need(item, missing: { _ in true }, into: &needs.metadata)
                    }
                    continue
                }
                if duration <= options.audioAnalysisMaxDuration, case .file = item.location {
                    need(item, missing: { $0.peakLevel == nil }, into: &needs.audioLevel)
                }
            }
        }
        needs.skippedCloudOnly = skipped.values.sortedBySizeDescending()
        return needs
    }

    // MARK: Classification

    public static func classify(
        items: [MediaItem],
        signatures: [String: MediaSignatures],
        options: ClassifierOptions = .default
    ) -> [String: [Classification]] {
        let valid = DuplicateDetector.validSignatures(items: items, signatures: signatures)
        let enrichedItems = items.map { DuplicateDetector.enriched($0, valid[$0.location.indexKey]) }
        let bursts = burstMembers(enrichedItems, signals: valid, window: options.burstWindow)

        var result: [String: [Classification]] = [:]
        for item in enrichedItems {
            let key = item.location.indexKey
            let signals = valid[key]?.classification ?? ClassificationSignals()
            let classifications = [
                forward(item, signals, inBurst: bursts.contains(key)),
                screenshot(item, signals),
                receipt(item, signals),
                lowQuality(item, signals, options),
            ]
            .compactMap { $0 }
            .filter { $0.confidence >= options.minimumConfidence }
            .sorted { $0.confidence > $1.confidence }
            if !classifications.isEmpty { result[key] = classifications }
        }
        return result
    }

    /// Classifies every item once; the outcome can be re-split whenever review preferences change.
    public static func outcome(
        items: [MediaItem],
        signatures: [String: MediaSignatures],
        options: ClassifierOptions = .default
    ) -> ClassificationOutcome {
        let valid = DuplicateDetector.validSignatures(items: items, signatures: signatures)
        let classifications = classify(items: items, signatures: signatures, options: options)
        return ClassificationOutcome(
            items: items
                .filter { classifications[$0.location.indexKey] != nil }
                .map { DuplicateDetector.enriched($0, valid[$0.location.indexKey]) },
            classifications: classifications
        )
    }

    /// Classifies and splits every category into "Likely to delete" and "Likely to keep".
    public static func review(
        items: [MediaItem],
        signatures: [String: MediaSignatures],
        options: ClassifierOptions = .default,
        preferences: ReviewPreferences = .default
    ) -> [CategoryReview] {
        outcome(items: items, signatures: signatures, options: options).reviews(preferences: preferences)
    }

    static func isFlaggedScreenshot(_ item: MediaItem) -> Bool {
        item.hints.contains(.screenshot) || item.hints.contains(.screenRecording)
            || FilenameHints.looksLikeScreenshot(item.filename) || FilenameHints.looksLikeScreenRecording(item.filename)
    }

    /// Camera originals are far larger than what messengers send, so only smaller photos (or ones
    /// with a messenger filename) need their metadata checked.
    static func couldBeForward(_ item: MediaItem) -> Bool {
        if FilenameHints.looksLikeMessagingApp(item.filename) { return true }
        guard let width = item.pixelWidth, let height = item.pixelHeight else { return true }
        return max(width, height) <= 2560
    }

    /// Combines independent pieces of evidence: each one removes part of the remaining doubt.
    private static func combine(_ evidence: [(ClassificationReason, Double)], category: CleanupCategory) -> Classification? {
        guard !evidence.isEmpty else { return nil }
        let doubt = evidence.reduce(1.0) { $0 * (1 - $1.1) }
        return Classification(category: category, confidence: 1 - doubt, reasons: evidence.map(\.0))
    }

    private static func forward(_ item: MediaItem, _ signals: ClassificationSignals, inBurst: Bool) -> Classification? {
        guard !isFlaggedScreenshot(item) else { return nil }
        var evidence: [(ClassificationReason, Double)] = []
        let namedByMessenger = FilenameHints.looksLikeMessagingApp(item.filename)
        if namedByMessenger { evidence.append((.messagingFilename, 0.85)) }
        if item.kind == .photo {
            if signals.hasCameraMetadata == false { evidence.append((.noCameraMetadata, 0.4)) }
            // Size and timing alone are too common to mean anything without other evidence.
            if namedByMessenger || signals.hasCameraMetadata == false {
                if ScreenSizes.isMessagingSize(width: item.pixelWidth, height: item.pixelHeight) {
                    evidence.append((.messagingResolution, 0.35))
                }
                if inBurst { evidence.append((.rapidSaveBurst, 0.3)) }
            }
        }
        return combine(evidence, category: .chatForwards)
    }

    private static func screenshot(_ item: MediaItem, _ signals: ClassificationSignals) -> Classification? {
        var evidence: [(ClassificationReason, Double)] = []
        if item.hints.contains(.screenshot) { evidence.append((.screenshotFlag, 0.99)) }
        if item.hints.contains(.screenRecording) { evidence.append((.screenRecordingFlag, 0.99)) }
        if FilenameHints.looksLikeScreenshot(item.filename) || FilenameHints.looksLikeScreenRecording(item.filename) {
            evidence.append((.screenshotFilename, 0.9))
        }
        if item.kind == .photo, signals.hasCameraMetadata != true,
           ScreenSizes.isScreenSize(width: item.pixelWidth, height: item.pixelHeight) {
            let isPNG = item.filename.map { ($0 as NSString).pathExtension.lowercased() == "png" } ?? false
            evidence.append((.screenSize, isPNG ? 0.75 : 0.5))
        }
        return combine(evidence, category: .screenshots)
    }

    private static func receipt(_ item: MediaItem, _ signals: ClassificationSignals) -> Classification? {
        guard item.kind == .photo else { return nil }
        var evidence: [(ClassificationReason, Double)] = []
        let documentConfidence = signals.documentConfidence ?? 0
        if documentConfidence >= 0.5 { evidence.append((.documentDetected, 0.4 * documentConfidence)) }
        if let text = signals.recognizedText {
            let found = ReceiptText.evidence(in: text)
            if !found.keywords.isEmpty { evidence.append((.receiptKeywords, 0.75 * min(1, Double(found.keywords.count) * 0.2))) }
            if found.hasAmount { evidence.append((.moneyAmount, 0.35)) }
            if found.hasTaxID { evidence.append((.taxID, 0.5)) }
        }
        return combine(evidence, category: .receipts)
    }

    private static func lowQuality(_ item: MediaItem, _ signals: ClassificationSignals, _ options: ClassifierOptions) -> Classification? {
        guard !isFlaggedScreenshot(item) else { return nil }
        var evidence: [(ClassificationReason, Double)] = []
        let isDocument = (signals.documentConfidence ?? 0) >= 0.5
            || signals.recognizedText.map { ReceiptText.evidence(in: $0).score >= 0.5 } ?? false

        if item.kind == .photo || item.kind == .video, let stats = signals.imageStats {
            let lowDetail = stats.standardDeviation < 12 && stats.edgeDensity < 0.02
            if lowDetail {
                evidence.append((.lowDetail, 0.6))
            } else if item.kind == .photo, !isDocument {
                if stats.laplacianVariance < 25 {
                    evidence.append((.blurry, 0.75))
                } else if stats.laplacianVariance < 60 {
                    evidence.append((.blurry, 0.45))
                }
            }
            if stats.meanLuminance < 30 || stats.darkFraction > 0.85 { evidence.append((.tooDark, 0.7)) }
            if !isDocument, stats.meanLuminance > 230 || stats.brightFraction > 0.8 { evidence.append((.overexposed, 0.6)) }
        }

        if item.kind == .video, let duration = item.duration, duration < options.shortVideoDuration {
            evidence.append((.shortVideo, 0.5))
            if let motion = signals.motion, motion < 6 { evidence.append((.lowMotion, 0.3)) }
        }

        if item.kind == .audio {
            if let duration = item.duration, duration < options.shortAudioDuration { evidence.append((.shortAudio, 0.6)) }
            if let peak = signals.peakLevel, peak < 0.01 { evidence.append((.nearSilent, 0.65)) }
        }
        return combine(evidence, category: .lowQuality)
    }

    /// Items without camera metadata (or with messenger names) saved within `window` seconds of at
    /// least two others like them, which is typical when a chat's media is saved in bulk.
    static func burstMembers(_ items: [MediaItem], signals: [String: MediaSignatures], window: TimeInterval) -> Set<String> {
        let candidates = items.filter { item in
            item.kind == .photo && item.creationDate != nil
                && (signals[item.location.indexKey]?.classification?.hasCameraMetadata == false
                    || FilenameHints.looksLikeMessagingApp(item.filename))
        }.sorted { $0.creationDate! < $1.creationDate! }

        var members = Set<String>()
        var start = 0
        for end in candidates.indices {
            while candidates[end].creationDate!.timeIntervalSince(candidates[start].creationDate!) > window { start += 1 }
            if end - start + 1 >= 3 {
                for i in start...end { members.insert(candidates[i].location.indexKey) }
            }
        }
        return members
    }
}
