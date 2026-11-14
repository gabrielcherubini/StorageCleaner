import StorageCleanerCore
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(ScanCoordinator.self) private var scanner
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

                Section("Overview") { SummaryRows(summary: scanner.summary) }

                AnalysisSettingsSection()

                DuplicatesSection()

                CategoriesSection()

                Section("Heaviest items") {
                    if scanner.summary.heaviest.isEmpty {
                        Text("Run a scan to see your largest photos, videos and audio files.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(scanner.summary.heaviest) { item in
                        MediaRow(item: item)
                    }
                }
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

private struct SummaryRows: View {
    let summary: LibrarySummary

    var body: some View {
        LabeledContent("Scanned", value: "\(summary.itemCount) items · \(formattedBytes(summary.totalBytes))")
        ForEach(MediaKind.allCases, id: \.self) { kind in
            LabeledContent(kind.title, value: "\(summary.count(of: kind)) · \(formattedBytes(summary.bytes(of: kind)))")
        }
        LabeledContent("Potential savings") {
            Text(formattedBytes(summary.potentialSavings.totalBytes)).bold()
        }
        LabeledContent(
            "Duplicates",
            value: "\(summary.potentialSavings.count(in: .duplicates)) · \(formattedBytes(summary.potentialSavings.bytes(in: .duplicates)))"
        )
        ForEach(CleanupCategory.classified, id: \.self) { category in
            LabeledContent(
                category.title,
                value: "\(summary.potentialSavings.count(in: category)) · \(formattedBytes(summary.potentialSavings.bytes(in: category)))"
            )
        }
        LabeledContent(
            "Large files (50 MB+)",
            value: "\(summary.potentialSavings.count(in: .largeFiles)) · \(formattedBytes(summary.potentialSavings.bytes(in: .largeFiles)))"
        )
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
        } header: {
            Text("Analysis")
        } footer: {
            Text("Analysis only reads your media. With downloads off, items stored only in iCloud are skipped.")
        }
    }
}

private struct DuplicatesSection: View {
    @Environment(ScanCoordinator.self) private var scanner

    var body: some View {
        Section {
            Button("Find Duplicates", systemImage: "square.on.square") { scanner.findDuplicates() }
                .disabled(scanner.isScanning || scanner.summary.itemCount == 0)

            if let report = scanner.duplicates {
                LabeledContent(
                    "\(report.groups.count) groups",
                    value: "\(formattedBytes(report.groups.map(\.reclaimableBytes).reduce(0, +))) reclaimable"
                )
                if report.skippedCloudOnly > 0 {
                    Label("\(report.skippedCloudOnly) items are only in iCloud and were not checked.", systemImage: "icloud")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if report.failed > 0 {
                    Label("\(report.failed) items could not be read.", systemImage: "exclamationmark.triangle")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(report.groups.prefix(100)) { group in
                    DuplicateGroupRow(group: group)
                }
            }
        } header: {
            Text("Duplicates")
        } footer: {
            Text("Exact copies are matched by size and SHA-256; similar photos, videos and audio by content. The suggested keeper is a favorite, then the highest resolution, then the oldest copy. Favorites, shared and edited items are never suggested for removal.")
        }
    }
}

private struct DuplicateGroupRow: View {
    let group: DuplicateGroup

    var body: some View {
        DisclosureGroup {
            ForEach(group.items) { item in
                HStack {
                    MediaRow(item: item)
                    badge(for: item)
                }
            }
        } label: {
            HStack {
                VStack(alignment: .leading) {
                    Text(group.keeper.filename ?? "Untitled").lineLimit(1)
                    Text("\(group.match.title) · \(group.items.count) copies")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(formattedBytes(group.reclaimableBytes)).monospacedDigit()
            }
        }
    }

    @ViewBuilder
    private func badge(for item: MediaItem) -> some View {
        if item.location == group.keeper.location {
            Text("Keep").font(.caption.bold()).foregroundStyle(.green)
        } else if item.isProtected {
            Text("Protected").font(.caption.bold()).foregroundStyle(.secondary)
        } else {
            Text("Suggested to remove").font(.caption.bold()).foregroundStyle(.orange)
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
    ContentView().environment(ScanCoordinator(container: try! IndexSchema.makeContainer(inMemory: true)))
}
