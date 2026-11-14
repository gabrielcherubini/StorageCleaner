import SwiftData
import SwiftUI

@main
struct StorageCleanerApp: App {
    private let container: ModelContainer
    @State private var scanner: ScanCoordinator

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
        _scanner = State(initialValue: ScanCoordinator(container: container))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(scanner)
        }
        .modelContainer(container)
    }
}
