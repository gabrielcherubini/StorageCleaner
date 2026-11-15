import StorageCleanerCore
import SwiftUI

/// An item's preview, or its kind's symbol when no preview is available.
///
/// The image is drawn in an overlay of a flexible rectangle, so it never takes part in layout:
/// the caller decides the frame (usually a fixed aspect ratio) and whatever doesn't fit is
/// clipped. Portrait, landscape and panoramic media all produce the same tile size.
struct ThumbnailView: View {
    @Environment(ThumbnailLoader.self) private var loader
    @Environment(ScanCoordinator.self) private var scanner
    let item: MediaItem
    var maxPixelSize = 360
    var contentMode: ContentMode = .fill

    @State private var image: CGImage?
    @State private var isLoading = true

    var body: some View {
        Rectangle()
            .fill(.quaternary)
            .overlay {
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: contentMode)
                } else if isLoading {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: placeholderSymbol)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
            }
            .clipped()
            .task(id: LoadKey(location: item.location, allowDownloads: scanner.allowICloudDownloads)) {
                let allow = scanner.allowICloudDownloads
                if let cached = loader.cachedThumbnail(for: item, maxPixelSize: maxPixelSize, allowDownloads: allow) {
                    image = cached
                    isLoading = false
                    return
                }
                isLoading = image == nil
                if let loaded = await loader.thumbnail(for: item, maxPixelSize: maxPixelSize, allowDownloads: allow) {
                    image = loaded
                }
                isLoading = false
            }
    }

    private var placeholderSymbol: String {
        if item.isLocallyAvailable == false { return "icloud" }
        return item.kind.symbolName
    }

    private struct LoadKey: Hashable {
        let location: MediaLocation
        let allowDownloads: Bool
    }
}

/// Grid cell: a square, clipped preview with size badge and selection control, plus a short
/// caption. Tapping the preview opens the viewer; the circle toggles selection.
struct MediaTile: View {
    let entry: ReviewEntry
    let isSelected: Bool
    var badge: TileBadge?
    var onOpen: () -> Void = {}
    var onToggle: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay { ThumbnailView(item: entry.item) }
                .clipShape(RoundedRectangle(cornerRadius: Theme.tileRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.tileRadius, style: .continuous)
                        .strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.06),
                                      lineWidth: isSelected ? 3 : 1)
                }
                .overlay(alignment: .bottomLeading) {
                    TileLabel(text: formattedBytes(entry.item.byteSize)).padding(6)
                }
                .overlay(alignment: .bottomTrailing) {
                    if let duration = entry.item.duration, entry.item.kind != .photo {
                        TileLabel(text: formattedDuration(duration), symbol: entry.item.kind == .video ? "play.fill" : "waveform")
                            .padding(6)
                    }
                }
                .overlay(alignment: .topLeading) {
                    if let badge {
                        TileLabel(text: badge.text).padding(6)
                    } else if entry.item.isProtected {
                        TileLabel(text: nil, symbol: entry.item.isFavorite ? "heart.fill" : "lock.fill")
                            .padding(6)
                            .accessibilityLabel(entry.item.protectionNote ?? "Protected")
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture(perform: onOpen)
                .contextMenu {
                    if let verdict = entry.verdict {
                        Text(verdict.explanation)
                        Divider()
                    }
                    Button("Open", systemImage: "arrow.up.left.and.arrow.down.right", action: onOpen)
                    Button(isSelected ? "Keep" : "Move to Trash", systemImage: isSelected ? "checkmark.circle" : "trash",
                           action: onToggle)
                }
                .help(entry.verdict?.explanation ?? "")
                .overlay(alignment: .topTrailing) {
                    Button(action: onToggle) {
                        SelectionMark(isSelected: isSelected)
                            .padding(6)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isSelected ? "Selected for Trash" : "Not selected")
                }

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.item.filename ?? "Untitled")
                    .font(.footnote)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let detail = entry.detail, !detail.isEmpty, entry.verdict != nil {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityHint(entry.verdict?.explanation ?? "")
        .accessibilityAction(named: isSelected ? "Deselect" : "Select", onToggle)
        .accessibilityAction(named: "Open", onOpen)
    }

    private var caption: String {
        if let verdict = entry.verdict { return verdict.summary }
        var parts: [String] = []
        if let confidence = entry.confidence {
            parts.append(confidence.formatted(.percent.precision(.fractionLength(0))))
        }
        if let detail = entry.detail, !detail.isEmpty {
            parts.append(detail)
        } else if let date = entry.item.creationDate {
            parts.append(date.formatted(date: .abbreviated, time: .omitted))
        }
        return parts.isEmpty ? entry.item.sourceName : parts.joined(separator: " · ")
    }
}

struct SelectionMark: View {
    let isSelected: Bool

    var body: some View {
        ZStack {
            Circle().fill(isSelected ? Color.accentColor : Color.black.opacity(0.25))
            Circle().strokeBorder(.white, lineWidth: 1.5)
            if isSelected {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: 24, height: 24)
        .shadow(color: .black.opacity(0.2), radius: 1, y: 0.5)
    }
}

/// Small dark capsule used on top of previews; readable on any image, in light and dark mode.
struct TileLabel: View {
    let text: String?
    var symbol: String?

    var body: some View {
        HStack(spacing: 3) {
            if let symbol { Image(systemName: symbol) }
            if let text { Text(text) }
        }
        .font(.caption2.weight(.semibold).monospacedDigit())
        .foregroundStyle(.white)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(.black.opacity(0.55), in: Capsule())
    }
}

struct TileBadge: Equatable {
    let text: String

    static let keep = TileBadge(text: "Keeper")
}

/// One reviewable item plus what the review screen shows about it.
struct ReviewEntry: Identifiable, Hashable {
    let item: MediaItem
    var confidence: Double?
    /// The classifier's signals, joined for display.
    var detail: String?
    var reason: DecisionReason?
    /// Why the item is in "Likely to delete" or "Likely to keep".
    var verdict: EntryVerdict?

    var id: MediaLocation { item.location }

    init(item: MediaItem, confidence: Double? = nil, detail: String? = nil, reason: DecisionReason? = nil,
         verdict: EntryVerdict? = nil) {
        self.item = item
        self.confidence = confidence
        self.detail = detail
        self.reason = reason
        self.verdict = verdict
    }

    init(_ classified: ClassifiedItem, preferences: ReviewPreferences) {
        var verdict = EntryVerdict(classified, preferences: preferences)
        if verdict.isLikelyDelete, !preferences.preselects(classified.classification.category) {
            verdict = verdict.withPreselectionOffNote
        }
        self.init(item: classified.item,
                  confidence: classified.classification.confidence,
                  detail: classified.classification.reasons.map(\.title).joined(separator: " · "),
                  reason: .category(classified.classification),
                  verdict: verdict)
    }

    init(duplicate item: MediaItem, in group: DuplicateGroup) {
        let verdict: EntryVerdict
        if item.location == group.keeper.location {
            verdict = EntryVerdict(summary: "Suggested keeper",
                                   explanation: "Kept: the best copy in this group (favorite first, then highest resolution, then oldest) is never pre-selected.",
                                   symbolName: "star", isLikelyDelete: false)
        } else if let note = item.protectionNote {
            verdict = EntryVerdict(summary: "Protected · \(note)",
                                   explanation: "Kept: \(note) items are never pre-selected, even as copies.",
                                   symbolName: "lock.fill", isLikelyDelete: false)
        } else {
            verdict = EntryVerdict(summary: "Extra copy",
                                   explanation: "Likely to delete: \(group.match.title.lowercased()) of the suggested keeper, which stays.",
                                   symbolName: "square.on.square", isLikelyDelete: true)
        }
        self.init(item: item, reason: .duplicate(of: group), verdict: verdict)
    }
}

enum Theme {
    static let tileRadius: CGFloat = 10
    static let gridSpacing: CGFloat = 12
    static let gridColumns = [GridItem(.adaptive(minimum: 104, maximum: 180), spacing: gridSpacing, alignment: .top)]
}
