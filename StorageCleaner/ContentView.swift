import StorageCleanerCore
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(ScanCoordinator.self) private var scanner
    @Environment(ThumbnailLoader.self) private var thumbnails
    @State private var isPickingFolder = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label(
                        "Scanning is read-only. Nothing is ever deleted permanently: items you confirm later go to Recently Deleted or the Trash.",
                        systemImage: "lock.shield"
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }

                if !scanner.errors.isEmpty {
                    Section {
                        ForEach(scanner.errors, id: \.self) { message in
                            Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                        }
                        Button("Dismiss") { scanner.dismissErrors() }
                    }
                }

                SourcesSection(isPickingFolder: $isPickingFolder)

                if let progress = scanner.progress {
                    Section("Scanning") { ScanProgressRow(progress: progress) }
                }

                StorageSection(summary: scanner.summary)

                SavingsSection()

                AnalysisSettingsSection()

                HeaviestSection()
            }
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
            .task { await scanner.load() }
            .onChange(of: scanner.folders) { thumbnails.resetAccess() }
        }
    }
}

private struct SourcesSection: View {
    @Environment(ScanCoordinator.self) private var scanner
    @Binding var isPickingFolder: Bool

    var body: some View {
        Section {
            HStack {
                Label("iCloud Photos", systemImage: "photo.on.rectangle")
                Spacer()
                switch scanner.photoAccess {
                case .full:
                    Text("Full access").foregroundStyle(.secondary)
                case .limited:
                    Text("Limited access").foregroundStyle(.orange)
                case .notDetermined:
                    Button("Allow access") { Task { await scanner.requestPhotoAccess() } }
                case .denied:
                    Text("No access (enable in Settings)").foregroundStyle(.red)
                }
            }

            ForEach(scanner.folders) { folder in
                HStack {
                    Label(folder.displayName, systemImage: "folder")
                    Spacer()
                    if let date = folder.lastScannedAt {
                        Text(date, format: .relative(presentation: .named)).foregroundStyle(.secondary)
                    }
                }
                .contextMenu {
                    Button("Scan this folder") { scanner.scan(folder: folder) }
                        .disabled(scanner.isScanning)
                    Button("Stop scanning this folder") { Task { await scanner.forget(folder: folder) } }
                        .disabled(scanner.isScanning)
                }
                .swipeActions {
                    Button("Stop scanning") { Task { await scanner.forget(folder: folder) } }
                        .disabled(scanner.isScanning)
                }
            }

            Button("Add Folder…", systemImage: "folder.badge.plus") { isPickingFolder = true }
        } header: {
            Text("Sources")
        } footer: {
            Text("Add your iCloud Drive folder to include its photos, videos and audio. “Stop scanning” only removes the folder from StorageCleaner; your files are not touched.")
        }
    }
}

private struct ScanProgressRow: View {
    let progress: ScanCoordinator.Progress

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let total = progress.total, total > 0 {
                ProgressView(value: Double(progress.done), total: Double(total)) {
                    Text("\(progress.detail ?? "\(progress.source): updating") — \(progress.done) of \(total) items")
                }
            } else {
                ProgressView {
                    Text("\(progress.source): \(progress.done) items found")
                }
            }
        }
    }
}

private struct StorageSection: View {
    let summary: LibrarySummary

    var body: some View {
        Section("Storage used") {
            LabeledContent("Scanned", value: "\(summary.itemCount) items · \(formattedBytes(summary.totalBytes))")
            ForEach(MediaKind.allCases, id: \.self) { kind in
                VStack(alignment: .leading, spacing: 4) {
                    LabeledContent {
                        Text("\(summary.count(of: kind)) · \(formattedBytes(summary.bytes(of: kind)))").monospacedDigit()
                    } label: {
                        Label(kind.title, systemImage: kind.symbolName)
                    }
                    ProgressView(value: summary.totalBytes > 0 ? Double(summary.bytes(of: kind)) / Double(summary.totalBytes) : 0)
                }
            }
        }
    }
}

/// Potential savings per category, each opening its review screen.
private struct SavingsSection: View {
    @Environment(ScanCoordinator.self) private var scanner

    var body: some View {
        let savings = scanner.summary.potentialSavings
        Section {
            LabeledContent("Potential savings") {
                Text(formattedBytes(savings.totalBytes)).bold().monospacedDigit()
            }

            NavigationLink(value: ReviewRoute.largeFiles) {
                row(.largeFiles, savings: savings)
            }

            if scanner.duplicates != nil {
                NavigationLink(value: ReviewRoute.duplicates) { row(.duplicates, savings: savings) }
            } else {
                HStack {
                    Label(CleanupCategory.duplicates.title, systemImage: CleanupCategory.duplicates.symbolName)
                    Spacer()
                    Button("Find Duplicates") { scanner.findDuplicates() }
                        .disabled(scanner.isScanning || scanner.summary.itemCount == 0)
                }
            }
            if let report = scanner.duplicates { notes(skipped: report.skippedCloudOnly, failed: report.failed) }

            if scanner.classifications != nil {
                ForEach(CleanupCategory.classified, id: \.self) { category in
                    NavigationLink(value: ReviewRoute.category(category)) { row(category, savings: savings) }
                }
            } else {
                HStack {
                    Label("Forwards, screenshots, receipts, low quality", systemImage: "square.grid.2x2")
                    Spacer()
                    Button("Analyze") { scanner.analyzeCategories() }
                        .disabled(scanner.isScanning || scanner.summary.itemCount == 0)
                }
            }
            if let report = scanner.classifications { notes(skipped: report.skippedCloudOnly, failed: report.failed) }
        } header: {
            Text("Cleanup")
        } footer: {
            Text("Sizes count items likely to delete; each item is counted once. Favorites, shared and edited items are never pre-selected. You review and confirm everything before anything moves to Recently Deleted or the Trash.")
        }
    }

    private func row(_ category: CleanupCategory, savings: SavingsTally) -> some View {
        HStack {
            Label(category.title, systemImage: category.symbolName)
            Spacer()
            VStack(alignment: .trailing) {
                Text(formattedBytes(savings.bytes(in: category))).monospacedDigit()
                Text("\(savings.count(in: category)) items").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func notes(skipped: Int, failed: Int) -> some View {
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

private struct AnalysisSettingsSection: View {
    @Environment(ScanCoordinator.self) private var scanner

    var body: some View {
        Section {
            Toggle("Download iCloud originals for analysis", isOn: Binding(
                get: { scanner.allowICloudDownloads },
                set: { scanner.setAllowICloudDownloads($0) }
            ))
            Toggle("Keep a decision log", isOn: Binding(
                get: { scanner.keepsDecisionLog },
                set: { scanner.setKeepsDecisionLog($0) }
            ))
        } header: {
            Text("Settings")
        } footer: {
            Text("Analysis only reads your media; with downloads off, items stored only in iCloud are skipped. The decision log is a local JSON file listing what was moved and why (\(DecisionLogStore.standard.url.path)).")
        }
    }
}

private struct HeaviestSection: View {
    @Environment(ScanCoordinator.self) private var scanner

    var body: some View {
        Section("Heaviest items") {
            if scanner.summary.heaviest.isEmpty {
                Text("Run a scan to see your largest photos, videos and audio files.")
                    .foregroundStyle(.secondary)
            }
            ForEach(scanner.summary.heaviest.prefix(8)) { item in
                MediaRow(item: item)
            }
            if !scanner.summary.heaviest.isEmpty {
                NavigationLink("Review heaviest items", value: ReviewRoute.heaviest)
            }
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

struct MediaRow: View {
    let item: MediaItem

    var body: some View {
        HStack {
            Image(systemName: item.kind.symbolName)
                .foregroundStyle(.tint)
                .frame(width: 24)
            VStack(alignment: .leading) {
                Text(item.filename ?? "Untitled").lineLimit(1)
                HStack(spacing: 6) {
                    Text(item.sourceName)
                    if let date = item.creationDate {
                        Text(date, format: .dateTime.year().month().day())
                    }
                    if item.isLocallyAvailable == false {
                        Image(systemName: "icloud")
                    }
                    if item.isFavorite {
                        Image(systemName: "heart.fill")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Text(formattedBytes(item.byteSize)).monospacedDigit()
        }
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
