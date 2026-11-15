import AVKit
import StorageCleanerCore
import SwiftUI

/// What to show in the viewer: the list the user was looking at and where to start.
struct ViewerRequest: Identifiable {
    let id = UUID()
    let entries: [ReviewEntry]
    let start: MediaLocation
}

/// Large viewer for reviewing one item at a time: zoom and pan for photos, playback for videos
/// and audio, swipe (or arrow keys) between items, and a Keep / Move to Trash control when the
/// screen has a selection. Previews follow the "Download iCloud originals" setting.
struct MediaViewer: View {
    @Environment(\.dismiss) private var dismiss
    let entries: [ReviewEntry]
    /// `nil` when the viewer is opened from a list without selection (for example the dashboard).
    let selection: Binding<ReviewSelection>?

    @State private var index: Int
    @State private var isZoomed = false
    @State private var dragOffset: CGFloat = 0
    @State private var showsChrome = true

    init(request: ViewerRequest, selection: Binding<ReviewSelection>?) {
        entries = request.entries
        self.selection = selection
        _index = State(initialValue: request.entries.firstIndex { $0.id == request.start } ?? 0)
    }

    private var entry: ReviewEntry? { entries.indices.contains(index) ? entries[index] : nil }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black.ignoresSafeArea()
                if let entry {
                    ViewerPage(entry: entry, isZoomed: $isZoomed)
                        .id(entry.id)
                        .offset(x: dragOffset)
                        .gesture(pagingGesture(width: proxy.size.width), including: isZoomed ? .subviews : .all)
                        .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { showsChrome.toggle() } }
                        .transition(.opacity)
                }
            }
            .overlay(alignment: .top) { if showsChrome { topBar } }
            .overlay(alignment: .bottom) { if showsChrome, let entry { bottomBar(for: entry) } }
        }
        .preferredColorScheme(.dark)
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) { move(by: -1); return .handled }
        .onKeyPress(.rightArrow) { move(by: 1); return .handled }
        .onKeyPress(.space) { toggleSelection(); return .handled }
        #if os(macOS)
        .frame(minWidth: 720, minHeight: 560)
        #endif
    }

    private func pagingGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 20)
            .onChanged { value in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                dragOffset = value.translation.width
            }
            .onEnded { value in
                let threshold = width * 0.2
                let step = value.translation.width < -threshold ? 1 : (value.translation.width > threshold ? -1 : 0)
                withAnimation(.easeOut(duration: 0.2)) {
                    dragOffset = 0
                    if step != 0 { move(by: step) }
                }
            }
    }

    private func move(by step: Int) {
        let target = index + step
        guard entries.indices.contains(target) else { return }
        isZoomed = false
        index = target
    }

    private func toggleSelection() {
        guard let selection, let entry else { return }
        selection.wrappedValue.toggle(entry.item)
    }

    private var topBar: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .frame(width: 36, height: 36)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel("Close")

            Spacer()
            Text("\(index + 1) of \(entries.count)")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer()

            HStack(spacing: 8) {
                Button { move(by: -1) } label: { Image(systemName: "chevron.left") }
                    .disabled(index == 0)
                    .accessibilityLabel("Previous")
                Button { move(by: 1) } label: { Image(systemName: "chevron.right") }
                    .disabled(index >= entries.count - 1)
                    .accessibilityLabel("Next")
            }
            .font(.body.weight(.semibold))
            .buttonStyle(.plain)
            .frame(height: 36)
            .padding(.horizontal, 12)
            .background(.ultraThinMaterial, in: Capsule())
        }
        .foregroundStyle(.white)
        .padding(.horizontal)
        .padding(.top, 8)
    }

    private func bottomBar(for entry: ReviewEntry) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.item.filename ?? "Untitled")
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(details(for: entry.item))
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
                if let explanation = entry.verdict?.explanation {
                    Label(explanation, systemImage: entry.verdict?.symbolName ?? "info.circle")
                        .font(.footnote)
                        .padding(.top, 4)
                } else if let note = entry.item.protectionNote {
                    Label("\(note) — never pre-selected", systemImage: "lock.fill")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if let detail = entry.detail, !detail.isEmpty {
                    Text("Signals: \(detail)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if let selection {
                Picker("Decision", selection: Binding(
                    get: { selection.wrappedValue.isSelected(entry.item) },
                    set: { wantsTrash in
                        if wantsTrash != selection.wrappedValue.isSelected(entry.item) {
                            selection.wrappedValue.toggle(entry.item)
                        }
                    }
                )) {
                    Label("Keep", systemImage: "checkmark.circle").tag(false)
                    Label("Move to Trash", systemImage: "trash").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel("Decision for this item")
            }
        }
        .foregroundStyle(.white)
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding()
    }

    private func details(for item: MediaItem) -> String {
        var parts = [formattedBytes(item.byteSize)]
        if let dimensions = item.dimensionsText { parts.append(dimensions) }
        if let duration = item.duration, item.kind != .photo { parts.append(formattedDuration(duration)) }
        if let date = item.creationDate { parts.append(date.formatted(date: .abbreviated, time: .shortened)) }
        parts.append(item.sourceName)
        return parts.joined(separator: " · ")
    }
}

/// One item: a zoomable photo, or a player for video and audio.
private struct ViewerPage: View {
    let entry: ReviewEntry
    @Binding var isZoomed: Bool

    var body: some View {
        switch entry.item.kind {
        case .photo: ZoomablePhoto(item: entry.item, isZoomed: $isZoomed)
        case .video, .audio: MediaPlayerView(item: entry.item)
        }
    }
}

private struct ZoomablePhoto: View {
    @Environment(ThumbnailLoader.self) private var loader
    @Environment(ScanCoordinator.self) private var scanner
    let item: MediaItem
    @Binding var isZoomed: Bool

    @State private var image: CGImage?
    @State private var state: LoadState = .loading
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .scaledToFit()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .scaleEffect(scale)
                        .offset(offset)
                        .gesture(magnify)
                        .simultaneousGesture(pan, including: scale > 1 ? .all : .subviews)
                        .onTapGesture(count: 2) { toggleZoom() }
                        .accessibilityLabel(item.filename ?? "Photo")
                        .accessibilityZoomAction { action in
                            withAnimation { setScale(action.direction == .zoomIn ? scale * 1.5 : scale / 1.5) }
                        }
                }
                LoadStateOverlay(state: state, hasImage: image != nil)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
        }
        .task(id: scanner.allowICloudDownloads) { await load() }
    }

    private func load() async {
        let allow = scanner.allowICloudDownloads
        image = image ?? loader.cachedThumbnail(for: item, maxPixelSize: 360, allowDownloads: allow)
        state = .loading
        do {
            image = try await loader.image(for: item, maxPixelSize: 2_400, allowDownloads: allow)
            state = .loaded
        } catch ThumbnailLoader.PreviewError.cloudOnly {
            state = .cloudOnly
        } catch {
            state = .failed
        }
    }

    private var magnify: some Gesture {
        MagnifyGesture()
            .onChanged { value in setScale(lastScale * value.magnification) }
            .onEnded { _ in
                lastScale = scale
                if scale <= 1 { withAnimation(.easeOut(duration: 0.2)) { reset() } }
            }
    }

    private var pan: some Gesture {
        DragGesture()
            .onChanged { value in
                guard scale > 1 else { return }
                offset = CGSize(width: lastOffset.width + value.translation.width,
                                height: lastOffset.height + value.translation.height)
            }
            .onEnded { _ in lastOffset = offset }
    }

    private func toggleZoom() {
        withAnimation(.easeInOut(duration: 0.25)) {
            if scale > 1 { reset() } else { setScale(2.5); lastScale = 2.5 }
        }
    }

    private func setScale(_ value: CGFloat) {
        scale = min(6, max(1, value))
        isZoomed = scale > 1
        if !isZoomed { offset = .zero; lastOffset = .zero }
    }

    private func reset() {
        scale = 1
        lastScale = 1
        offset = .zero
        lastOffset = .zero
        isZoomed = false
    }
}

private struct MediaPlayerView: View {
    @Environment(ThumbnailLoader.self) private var loader
    @Environment(ScanCoordinator.self) private var scanner
    let item: MediaItem

    @State private var player: AVPlayer?
    @State private var scope: SecurityScope?
    @State private var state: LoadState = .loading

    var body: some View {
        ZStack {
            if let player {
                VideoPlayer(player: player)
                    .accessibilityLabel(item.filename ?? "Video")
            } else {
                ThumbnailView(item: item, maxPixelSize: 900, contentMode: .fit)
                    .background(Color.black)
            }
            LoadStateOverlay(state: state, hasImage: player != nil)
        }
        .task(id: scanner.allowICloudDownloads) { await load() }
        .onDisappear {
            player?.pause()
            player = nil
            scope = nil
        }
    }

    private func load() async {
        state = .loading
        do {
            let (playerItem, scope) = try await loader.playerItem(for: item, allowDownloads: scanner.allowICloudDownloads)
            self.scope = scope
            player = AVPlayer(playerItem: playerItem)
            state = .loaded
        } catch ThumbnailLoader.PreviewError.cloudOnly {
            state = .cloudOnly
        } catch {
            state = .failed
        }
    }
}

private enum LoadState: Equatable {
    case loading, loaded, cloudOnly, failed
}

private struct LoadStateOverlay: View {
    let state: LoadState
    let hasImage: Bool

    var body: some View {
        switch state {
        case .loaded:
            EmptyView()
        case .loading:
            ProgressView()
                .controlSize(.large)
                .tint(.white)
                .padding(20)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .opacity(hasImage ? 0.8 : 1)
        case .cloudOnly:
            message("Stored only in iCloud",
                    detail: hasImage
                        ? "Showing a small preview. Turn on “Download iCloud originals” in Settings to see it in full."
                        : "Turn on “Download iCloud originals” in Settings to preview it.",
                    symbol: "icloud")
        case .failed:
            message("Preview unavailable", detail: "This item couldn't be opened.", symbol: "exclamationmark.triangle")
        }
    }

    private func message(_ title: String, detail: String, symbol: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: symbol).font(.title2)
            Text(title).font(.headline)
            Text(detail).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .foregroundStyle(.white)
        .padding()
        .frame(maxWidth: 320)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

extension View {
    /// Presents the viewer full screen on iPhone and iPad, and as a large sheet on the Mac.
    func mediaViewer(_ request: Binding<ViewerRequest?>, selection: Binding<ReviewSelection>?) -> some View {
        #if os(iOS)
        fullScreenCover(item: request) { request in
            MediaViewer(request: request, selection: selection)
        }
        #else
        sheet(item: request) { request in
            MediaViewer(request: request, selection: selection)
        }
        #endif
    }
}
