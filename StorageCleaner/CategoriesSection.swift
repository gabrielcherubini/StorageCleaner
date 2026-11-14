import StorageCleanerCore
import SwiftUI

struct CategoriesSection: View {
    @Environment(ScanCoordinator.self) private var scanner

    var body: some View {
        Section {
            Button("Analyze Categories", systemImage: "square.grid.2x2") { scanner.analyzeCategories() }
                .disabled(scanner.isScanning || scanner.summary.itemCount == 0)

            if let report = scanner.classifications {
                if report.reviews.isEmpty {
                    Text("No chat forwards, screenshots, receipts or low-quality items found.")
                        .foregroundStyle(.secondary)
                }
                if report.skippedCloudOnly > 0 {
                    Label("\(report.skippedCloudOnly) items are only in iCloud and were not fully checked.", systemImage: "icloud")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if report.failed > 0 {
                    Label("\(report.failed) items could not be read.", systemImage: "exclamationmark.triangle")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(report.reviews) { review in
                    CategoryReviewRow(review: review)
                }
            }
        } header: {
            Text("Categories")
        } footer: {
            Text("Each item gets a category and a confidence. Only items in “Likely to delete” will start selected for review; favorites, shared and edited items are always in “Likely to keep” and never pre-selected.")
        }
    }
}

private struct CategoryReviewRow: View {
    let review: CategoryReview
    private let limit = 100

    var body: some View {
        DisclosureGroup {
            if !review.likelyToDelete.isEmpty {
                Text("Likely to delete · \(review.likelyToDelete.count)")
                    .font(.caption.bold()).foregroundStyle(.orange)
                ForEach(review.likelyToDelete.prefix(limit)) { ClassifiedItemRow(entry: $0) }
            }
            if !review.likelyToKeep.isEmpty {
                Text("Likely to keep · \(review.likelyToKeep.count)")
                    .font(.caption.bold()).foregroundStyle(.green)
                ForEach(review.likelyToKeep.prefix(limit)) { ClassifiedItemRow(entry: $0) }
            }
        } label: {
            HStack {
                Label(review.category.title, systemImage: review.category.symbolName)
                Spacer()
                VStack(alignment: .trailing) {
                    Text(formattedBytes(review.likelyToDeleteBytes)).monospacedDigit()
                    Text("\(review.likelyToDelete.count) likely to delete · \(review.likelyToKeep.count) to keep")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct ClassifiedItemRow: View {
    let entry: ClassifiedItem

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                MediaRow(item: entry.item)
                Text(entry.classification.confidence, format: .percent.precision(.fractionLength(0)))
                    .font(.caption.bold().monospacedDigit())
                    .foregroundStyle(entry.isPreselected ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
            }
            Text(reasonText)
                .font(.caption2).foregroundStyle(.secondary)
                .padding(.leading, 32)
        }
    }

    private var reasonText: String {
        var parts = entry.classification.reasons.map(\.title)
        if entry.item.isProtected { parts.insert("Protected", at: 0) }
        return parts.joined(separator: " · ")
    }
}

extension CleanupCategory {
    static let classified: [CleanupCategory] = [.chatForwards, .screenshots, .receipts, .lowQuality]

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
