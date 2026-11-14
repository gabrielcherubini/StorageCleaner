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
                    Text("\(progress.source): updating \(progress.done) of \(total) items")
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
            "Large files (50 MB+)",
            value: "\(summary.potentialSavings.count(in: .largeFiles)) · \(formattedBytes(summary.potentialSavings.bytes(in: .largeFiles)))"
        )
    }
}

private struct MediaRow: View {
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
