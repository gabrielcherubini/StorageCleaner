import SwiftData
import SwiftUI

@main
struct StorageCleanerApp: App {
    private let container: ModelContainer
    @State private var scanner: ScanCoordinator
    @State private var trash: TrashCoordinator
    @State private var thumbnails: ThumbnailLoader

    init() {
        let container: ModelContainer
        do {
            container = try IndexSchema.makeContainer()
        } catch {
            // The index is only a cache of scan results, so an unreadable store falls back to an
            // in-memory one and the next scan rebuilds it.
            container = try! IndexSchema.makeContainer(inMemory: true)
        }
        self.container = container
        let scanner = ScanCoordinator(container: container)
        _scanner = State(initialValue: scanner)
        _trash = State(initialValue: TrashCoordinator(scanner: scanner))
        _thumbnails = State(initialValue: ThumbnailLoader(store: scanner.store))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(scanner)
                .environment(trash)
                .environment(thumbnails)
        }
        .modelContainer(container)
    }
}
