import StorageCleanerCore
import SwiftUI

extension CleanupCategory {
    static let classified: [CleanupCategory] = [.chatForwards, .screenshots, .receipts, .lowQuality]

    var explanation: String {
        switch self {
        case .largeFiles: return "Photos, videos and audio of 50 MB or more. Nothing is pre-selected."
        case .duplicates: return "Exact copies and similar photos, videos and audio. The suggested keeper is never pre-selected."
        case .chatForwards: return "Media saved from WhatsApp, Telegram, Signal and other messaging apps."
        case .screenshots: return "Screenshots and screen recordings."
        case .receipts: return "Receipts, invoices and other photographed documents."
        case .lowQuality: return "Blurry, dark or overexposed shots, accidental pocket photos, and very short videos or audio."
        }
    }

    var title: String {
        switch self {
        case .largeFiles: return "Large files"
        case .duplicates: return "Duplicates"
        case .chatForwards: return "Chat & app forwards"
        case .screenshots: return "Screenshots & recordings"
        case .receipts: return "Receipts & documents"
        case .lowQuality: return "Low quality"
        }
    }

    var symbolName: String {
        switch self {
        case .largeFiles: return "externaldrive"
        case .duplicates: return "square.on.square"
        case .chatForwards: return "bubble.left.and.bubble.right"
        case .screenshots: return "camera.viewfinder"
        case .receipts: return "doc.text"
        case .lowQuality: return "camera.metering.unknown"
        }
    }
}

extension ClassificationReason {
    var title: String {
        switch self {
        case .messagingFilename: return "Messaging app name"
        case .noCameraMetadata: return "No camera info"
        case .messagingResolution: return "Messaging app size"
        case .rapidSaveBurst: return "Saved in a batch"
        case .screenshotFlag: return "Marked as screenshot"
        case .screenRecordingFlag: return "Marked as screen recording"
        case .screenshotFilename: return "Screenshot name"
        case .screenSize: return "Screen-sized"
        case .documentDetected: return "Looks like a document"
        case .receiptKeywords: return "Receipt words"
        case .moneyAmount: return "Money amounts"
        case .taxID: return "CNPJ/CPF"
        case .blurry: return "Blurry"
        case .tooDark: return "Too dark"
        case .overexposed: return "Overexposed"
        case .lowDetail: return "Ground or pocket shot"
        case .shortVideo: return "Very short video"
        case .lowMotion: return "Almost no motion"
        case .shortAudio: return "Very short audio"
        case .nearSilent: return "Nearly silent"
        }
    }
}

extension MediaItem {
    var protectionNote: String? {
        var notes: [String] = []
        if isFavorite { notes.append("Favorite") }
        if isInSharedAlbum { notes.append("Shared") }
        if isEdited { notes.append("Edited") }
        return notes.isEmpty ? nil : notes.joined(separator: ", ")
    }

    var dimensionsText: String? {
        guard let width = pixelWidth, let height = pixelHeight else { return nil }
        return "\(width) × \(height)"
    }
}

func formattedDuration(_ seconds: TimeInterval) -> String {
    let formatter = DateComponentsFormatter()
    formatter.allowedUnits = seconds >= 3_600 ? [.hour, .minute, .second] : [.minute, .second]
    formatter.zeroFormattingBehavior = .pad
    return formatter.string(from: seconds) ?? "\(Int(seconds))s"
}
