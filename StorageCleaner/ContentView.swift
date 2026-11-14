import StorageCleanerCore
import SwiftUI

struct ContentView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "externaldrive.badge.checkmark")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            Text("StorageCleaner")
                .font(.largeTitle.bold())
            Text("Find heavy, duplicate and throwaway media in iCloud Photos and iCloud Drive.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Label(
                "Nothing is ever deleted permanently. Items you confirm go to Recently Deleted or the Trash.",
                systemImage: "lock.shield"
            )
            .font(.footnote)
            .padding()
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
        }
        .padding(32)
        .frame(maxWidth: 520)
    }
}

#Preview {
    ContentView()
}
