import StorageCleanerCore
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(ScanCoordinator.self) private var scanner
    @Environment(ThumbnailLoader.self) private var thumbnails
    @State private var isPickingFolder = false
    @State private var path = NavigationPath()
    @State private var viewer: ViewerRequest?

    var body: some View {
        NavigationStack(path: $path) {
            List {
                OverviewSection()

                if !scanner.errors.isEmpty {
                    Section {
                        ForEach(scanner.errors, id: \.self) { message in
                            Label(message, systemImage: "exclamationmark.triangle")
                                .font(.subheadline)
                                .foregroundStyle(.orange)
                        }
                        Button("Dismiss") { scanner.dismissErrors() }
                    }
                }

                if let progress = scanner.progress {
                    Section { ScanProgressRow(progress: progress) }
                }

                if scanner.summary.itemCount > 0 {
                    CleanupSection()
                    HeaviestSection(viewer: $viewer)
                }

                SourcesSection(isPickingFolder: $isPickingFolder)

                SettingsSection()
            }
            #if os(iOS)
            .listStyle(.insetGrouped)
            #endif
            .mediaViewer($viewer, selection: nil)
            .navigationDestination(for: ReviewRoute.self) { route in
                ReviewDestination(route: route)
            }
            .navigationTitle("StorageCleaner")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    if scanner.isScanning {
                        Button("Stop", systemImage: "stop.circle") { scanner.cancel() }
                    } else {
                        Button("Scan", systemImage: "arrow.clockwise") { scanner.scanEverything() }
                    }
                }
            }
            .fileImporter(isPresented: $isPickingFolder, allowedContentTypes: [.folder]) { result in
                if case let .success(url) = result {
                    Task { await scanner.addFolder(at: url) }
                }
            }
            .task {
                #if DEBUG
                if let route = DemoMode.initialRoute { path.append(route) }
                if DemoMode.isActive { return }
                #endif
                await scanner.load()
            }
            .onChange(of: scanner.folders) { thumbnails.resetAccess() }
        }
    }
}

/// Headline numbers: what can be freed, and what the scanned media takes up.
private struct OverviewSection: View {
    @Environment(ScanCoordinator.self) private var scanner

    var body: some View {
        let summary = scanner.summary
        Section {
            if summary.itemCount == 0 {
                VStack(spacing: 12) {
                    Image(systemName: "externaldrive.badge.icloud")
                        .font(.system(size: 40, weight: .light))
                        .foregroundStyle(.tint)
                    Text("Find what's taking up space")
                        .font(.title3.weight(.semibold))
                    Text("Scan iCloud Photos and the iCloud Drive folders you add. Scanning only reads your media.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button {
                        scanner.scanEverything()
                    } label: {
                        Text(scanner.isScanning ? "Scanning…" : "Scan Now").frame(minWidth: 140)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(scanner.isScanning)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Potential savings")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text(formattedBytes(summary.potentialSavings.totalBytes))
                            .font(.system(.largeTitle, design: .rounded).weight(.semibold))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                        Text("\(summary.itemCount.formatted()) items scanned · \(formattedBytes(summary.totalBytes)) in use")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    StorageBar(summary: summary)
                }
                .padding(.vertical, 6)
            }
        } footer: {
            Label("Nothing is ever deleted permanently. Items you confirm go to Recently Deleted or the Trash.",
                  systemImage: "lock.shield")
        }
    }
}

/// Share of storage per media kind, as one segmented bar with a legend.
private struct StorageBar: View {
    let summary: LibrarySummary

    private static let shades: [MediaKind: Double] = [.photo: 1, .video: 0.6, .audio: 0.3]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { proxy in
                HStack(spacing: 2) {
                    ForEach(MediaKind.allCases, id: \.self) { kind in
                        let fraction = summary.totalBytes > 0 ? Double(summary.bytes(of: kind)) / Double(summary.totalBytes) : 0
                        if fraction > 0 {
                            Rectangle()
                                .fill(Color.accentColor.opacity(Self.shades[kind] ?? 1))
                                .frame(width: max(2, (proxy.size.width - 4) * fraction))
                        }
                    }
                }
            }
            .frame(height: 8)
            .background(.quaternary)
            .clipShape(Capsule())

            HStack(spacing: 14) {
                ForEach(MediaKind.allCases, id: \.self) { kind in
                    HStack(spacing: 5) {
                        Circle().fill(Color.accentColor.opacity(Self.shades[kind] ?? 1)).frame(width: 7, height: 7)
                        Text(kind.title)
                        Text(formattedBytes(summary.bytes(of: kind))).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            }
            .font(.caption)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Potential savings per category, each opening its review screen.
private struct CleanupSection: View {
    @Environment(ScanCoordinator.self) private var scanner

    var body: some View {
        let savings = scanner.summary.potentialSavings
        Section {
            NavigationLink(value: ReviewRoute.largeFiles) {
                CategoryRow(category: .largeFiles, count: savings.count(in: .largeFiles), bytes: savings.bytes(in: .largeFiles))
            }

            if scanner.duplicates != nil {
                NavigationLink(value: ReviewRoute.duplicates) {
                    CategoryRow(category: .duplicates, count: savings.count(in: .duplicates), bytes: savings.bytes(in: .duplicates))
                }
            } else {
                ActionRow(title: CleanupCategory.duplicates.title, symbol: CleanupCategory.duplicates.symbolName,
                          button: "Find") { scanner.findDuplicates() }
                    .disabled(scanner.isScanning)
            }

            if scanner.classifications != nil {
                ForEach(CleanupCategory.classified, id: \.self) { category in
                    NavigationLink(value: ReviewRoute.category(category)) {
                        CategoryRow(category: category, count: savings.count(in: category), bytes: savings.bytes(in: category))
                    }
                }
            } else {
                ActionRow(title: "Forwards, screenshots, receipts and low quality", symbol: "square.grid.2x2",
                          button: "Analyze") { scanner.analyzeCategories() }
                    .disabled(scanner.isScanning)
            }

            notes
        } header: {
            Text("Cleanup")
        } footer: {
            Text("Sizes count items likely to delete, each counted once. Favorites, shared and edited items are never pre-selected.")
        }
    }

    @ViewBuilder
    private var notes: some View {
        let skipped = max(scanner.duplicates?.skippedCloudOnly ?? 0, scanner.classifications?.skippedCloudOnly ?? 0)
        let failed = max(scanner.duplicates?.failed ?? 0, scanner.classifications?.failed ?? 0)
        if skipped > 0 {
            Label("\(skipped) items are only in iCloud and were not fully checked.", systemImage: "icloud")
                .font(.footnote).foregroundStyle(.secondary)
        }
        if failed > 0 {
            Label("\(failed) items could not be read.", systemImage: "exclamationmark.triangle")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }
}

/// A list row with a tinted symbol tile, a title and a trailing value.
struct IconTile: View {
    let symbol: String

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(.tint)
            .frame(width: 32, height: 32)
            .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct CategoryRow: View {
    let category: CleanupCategory
    let count: Int
    let bytes: Int64

    var body: some View {
        HStack(spacing: 12) {
            IconTile(symbol: category.symbolName)
            VStack(alignment: .leading, spacing: 2) {
                Text(category.title)
                Text(count == 0 ? "Nothing to remove" : "\(count) \(count == 1 ? "item" : "items")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(formattedBytes(bytes))
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(count == 0 ? .secondary : .primary)
        }
        .padding(.vertical, 2)
    }
}

private struct ActionRow: View {
    let title: String
    let symbol: String
    let button: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            IconTile(symbol: symbol)
            Text(title).lineLimit(2)
            Spacer()
            Button(button, action: action)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(.vertical, 2)
    }
}

private struct HeaviestSection: View {
    @Environment(ScanCoordinator.self) private var scanner
    @Binding var viewer: ViewerRequest?

    var body: some View {
        let items = Array(scanner.summary.heaviest.prefix(5))
        Section {
            ForEach(items) { item in
                Button {
                    viewer = ViewerRequest(entries: items.map { ReviewEntry(item: $0) }, start: item.location)
                } label: {
                    MediaRow(item: item)
                }
                .buttonStyle(.plain)
            }
            NavigationLink("See All", value: ReviewRoute.heaviest)
        } header: {
            Text("Heaviest items")
        }
    }
}

private struct SourcesSection: View {
    @Environment(ScanCoordinator.self) private var scanner
    @Binding var isPickingFolder: Bool

    var body: some View {
        Section {
            HStack(spacing: 12) {
                IconTile(symbol: "photo.on.rectangle")
                Text("iCloud Photos")
                Spacer()
                switch scanner.photoAccess {
                case .full:
                    Text("Full access").font(.subheadline).foregroundStyle(.secondary)
                case .limited:
                    Text("Limited access").font(.subheadline).foregroundStyle(.secondary)
                case .notDetermined:
                    Button("Allow Access") { Task { await scanner.requestPhotoAccess() } }
                        .buttonStyle(.bordered).controlSize(.small)
                case .denied:
                    Text("Off in Settings").font(.subheadline).foregroundStyle(.secondary)
                }
            }

            ForEach(scanner.folders) { folder in
                HStack(spacing: 12) {
                    IconTile(symbol: "folder")
                    VStack(alignment: .leading, spacing: 2) {
                        Text(folder.displayName)
                        if let date = folder.lastScannedAt {
                            Text("Scanned \(date, format: .relative(presentation: .named))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .contextMenu {
                    Button("Scan This Folder") { scanner.scan(folder: folder) }
                        .disabled(scanner.isScanning)
                    Button("Stop Scanning This Folder") { Task { await scanner.forget(folder: folder) } }
                        .disabled(scanner.isScanning)
                }
                .swipeActions {
                    Button("Stop Scanning") { Task { await scanner.forget(folder: folder) } }
                        .disabled(scanner.isScanning)
                }
            }

            Button {
                isPickingFolder = true
            } label: {
                Label("Add iCloud Drive Folder…", systemImage: "plus")
            }
        } header: {
            Text("Sources")
        } footer: {
            Text("“Stop scanning” only removes a folder from StorageCleaner; your files are not touched.")
        }
    }
}

private struct ScanProgressRow: View {
    let progress: ScanCoordinator.Progress

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let total = progress.total, total > 0 {
                ProgressView(value: Double(progress.done), total: Double(total)) {
                    Text(progress.detail ?? "Updating \(progress.source)").font(.subheadline)
                } currentValueLabel: {
                    Text("\(progress.done) of \(total)").monospacedDigit()
                }
            } else {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("\(progress.source) · \(progress.done) items found").font(.subheadline).monospacedDigit()
                }
            }
        }
        .padding(.vertical, 2)
    }
}

private struct SettingsSection: View {
    @Environment(ScanCoordinator.self) private var scanner

    var body: some View {
        Section {
            NavigationLink(value: ReviewRoute.rules) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Review Rules")
                    Text("Strictness, pre-selection and simple rules per category.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Toggle(isOn: Binding(get: { scanner.allowICloudDownloads }, set: { scanner.setAllowICloudDownloads($0) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Download iCloud originals")
                    Text("For analysis and previews of items stored only in iCloud.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Toggle(isOn: Binding(get: { scanner.keepsDecisionLog }, set: { scanner.setKeepsDecisionLog($0) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Keep a decision log")
                    Text("A local JSON file of what was moved and why.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Settings")
        }
    }
}

extension DuplicateGroup.Match {
    var title: String {
        switch self {
        case .exact: return "Exact copies"
        case .similarPhoto: return "Similar photos"
        case .similarVideo: return "Similar videos"
        case .similarAudio: return "Similar audio"
        }
    }
}

/// A list row with a small clipped preview, name, details and size.
struct MediaRow: View {
    let item: MediaItem

    var body: some View {
        HStack(spacing: 12) {
            ThumbnailView(item: item, maxPixelSize: 120)
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.filename ?? "Untitled")
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 4) {
                    Text(item.sourceName)
                    if let date = item.creationDate {
                        Text("·")
                        Text(date, format: .dateTime.year().month(.abbreviated).day())
                    }
                    if item.isLocallyAvailable == false {
                        Image(systemName: "icloud").accessibilityLabel("Only in iCloud")
                    }
                    if item.isProtected {
                        Image(systemName: item.isFavorite ? "heart.fill" : "lock.fill")
                            .accessibilityLabel(item.protectionNote ?? "Protected")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text(formattedBytes(item.byteSize))
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
    }
}

func formattedBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

extension MediaKind {
    var title: String {
        switch self {
        case .photo: return "Photos"
        case .video: return "Videos"
        case .audio: return "Audio"
        }
    }

    var symbolName: String {
        switch self {
        case .photo: return "photo"
        case .video: return "video"
        case .audio: return "waveform"
        }
    }
}

extension MediaItem {
    var sourceName: String {
        switch location {
        case .photoLibrary: return "Photos"
        case .file: return "iCloud Drive"
        }
    }
}

#Preview {
    let scanner = ScanCoordinator(container: try! IndexSchema.makeContainer(inMemory: true))
    return ContentView()
        .environment(scanner)
        .environment(TrashCoordinator(scanner: scanner))
        .environment(ThumbnailLoader(store: scanner.store))
}
