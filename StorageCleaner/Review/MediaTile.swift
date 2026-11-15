import StorageCleanerCore
import SwiftUI

/// An item's preview, or its kind's symbol when no local preview is available.
struct ThumbnailView: View {
    @Environment(ThumbnailLoader.self) private var loader
    let item: MediaItem
    var maxPixelSize = 320

    @State private var image: CGImage?

    var body: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: item.isLocallyAvailable == false ? "icloud" : item.kind.symbolName)
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
        }
        .clipped()
        .task(id: item.location) {
            image = await loader.thumbnail(for: item, maxPixelSize: maxPixelSize)
        }
    }
}

/// Grid cell: preview with size badge, selection mark, and protection / confidence markers.
struct MediaTile: View {
    let entry: ReviewEntry
    let isSelected: Bool
    var badge: TileBadge?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ThumbnailView(item: entry.item)
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(alignment: .bottomLeading) {
                    Text(formattedBytes(entry.item.byteSize))
                        .font(.caption2.bold().monospacedDigit())
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.black.opacity(0.6), in: Capsule())
                        .foregroundStyle(.white)
                        .padding(6)
                }
                .overlay(alignment: .bottomTrailing) {
                    if let duration = entry.item.duration, entry.item.kind != .photo {
                        Text(formattedDuration(duration))
                            .font(.caption2.monospacedDigit())
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.black.opacity(0.6), in: Capsule())
                            .foregroundStyle(.white)
                            .padding(6)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(Color.white, isSelected ? Color.accentColor : Color.black.opacity(0.35))
                        .padding(6)
                }
                .overlay(alignment: .topLeading) {
                    HStack(spacing: 4) {
                        if entry.item.isProtected {
                            Image(systemName: entry.item.isFavorite ? "heart.fill" : "lock.fill")
                                .help(entry.item.protectionNote ?? "Protected")
                        }
                        if let badge {
                            Text(badge.text).foregroundStyle(badge.color)
                        } else if let confidence = entry.confidence {
                            Text(confidence, format: .percent.precision(.fractionLength(0)))
                        }
                    }
                    .font(.caption2.bold())
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.black.opacity(0.6), in: Capsule())
                    .foregroundStyle(.white)
                    .padding(6)
                    .opacity(entry.item.isProtected || badge != nil || entry.confidence != nil ? 1 : 0)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 3)
                }

            Text(entry.item.filename ?? "Untitled")
                .font(.caption).lineLimit(1)
            if let detail = entry.detail {
                Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }
}

struct TileBadge: Equatable {
    let text: String
    let color: Color

    static let keep = TileBadge(text: "Keep", color: .green)
}

/// One reviewable item plus what the review screen shows about it.
struct ReviewEntry: Identifiable, Hashable {
    let item: MediaItem
    var confidence: Double?
    var detail: String?
    var reason: DecisionReason?

    var id: MediaLocation { item.location }

    init(item: MediaItem, confidence: Double? = nil, detail: String? = nil, reason: DecisionReason? = nil) {
        self.item = item
        self.confidence = confidence
        self.detail = detail
        self.reason = reason
    }

    init(_ classified: ClassifiedItem) {
        self.init(item: classified.item,
                  confidence: classified.classification.confidence,
                  detail: classified.classification.reasons.map(\.title).joined(separator: " · "),
                  reason: .category(classified.classification))
    }
}
