import StorageCleanerCore
import SwiftUI

/// What a review screen hands to the confirm sheet.
struct PendingTrash: Identifiable {
    let id = UUID()
    let plan: TrashPlan
    let reasons: [MediaLocation: DecisionReason]
    var warnings: [String] = []
}

/// The final confirm sheet. It shows the exact count and total size, and the confirmation it
/// produces echoes those numbers, so `TrashPlan.confirm` rejects anything the user didn't see.
struct ConfirmTrashSheet: View {
    let pending: PendingTrash
    let onConfirm: (TrashConfirmation) -> Void
    let onCancel: () -> Void

    private var plan: TrashPlan { pending.plan }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Move \(plan.itemCount) \(plan.itemCount == 1 ? "item" : "items")?")
                            .font(.title2.bold())
                        Text(formattedBytes(plan.totalBytes))
                            .font(.title3.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)

                    let photos = plan.photoLibraryItems
                    if !photos.isEmpty {
                        Label {
                            Text("\(photos.count) from Photos (\(formattedBytes(photos.totalByteSize))) go to **Recently Deleted**, where they stay for 30 days. Photos will ask you to confirm once more.")
                        } icon: {
                            Image(systemName: "photo.on.rectangle")
                        }
                    }
                    let files = plan.fileItems
                    if !files.isEmpty {
                        Label {
                            Text("\(files.count) from iCloud Drive (\(formattedBytes(files.totalByteSize))) go to the **Trash**, where they stay until you empty it.")
                        } icon: {
                            Image(systemName: "trash")
                        }
                    }
                    Label("Nothing is deleted permanently.", systemImage: "lock.shield")
                        .foregroundStyle(.secondary)
                }

                let protectedCount = plan.items.filter(\.isProtected).count
                if protectedCount > 0 || !pending.warnings.isEmpty {
                    Section {
                        if protectedCount > 0 {
                            Label("\(protectedCount) favorite, shared or edited \(protectedCount == 1 ? "item was" : "items were") selected by hand.",
                                  systemImage: "exclamationmark.triangle")
                        }
                        ForEach(pending.warnings, id: \.self) { warning in
                            Label(warning, systemImage: "exclamationmark.triangle")
                        }
                    }
                    .foregroundStyle(.orange)
                }

                Section("Items") {
                    ForEach(plan.items) { item in
                        MediaRow(item: item)
                    }
                }
            }
            .navigationTitle("Confirm")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(role: .destructive) {
                        onConfirm(TrashConfirmation(acknowledgedItemCount: plan.itemCount,
                                                    acknowledgedTotalBytes: plan.totalBytes))
                    } label: {
                        Text("Move \(plan.itemCount) to Trash")
                    }
                    .tint(.red)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 520)
        #endif
    }
}

/// Shown after `TrashService` ran: what moved where, what didn't, and where to restore from.
struct TrashSummarySheet: View {
    let outcome: TrashCoordinator.Outcome
    let onDone: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Moved \(outcome.result.moved.count) of \(outcome.confirmedCount) items")
                            .font(.title2.bold())
                        Text("\(formattedBytes(outcome.result.movedBytes)) can be freed")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                    if outcome.recentlyDeletedCount > 0 {
                        Label("\(outcome.recentlyDeletedCount) in Photos › Recently Deleted. They stay there for 30 days and can be recovered; the space is freed when they are removed from there.",
                              systemImage: "photo.on.rectangle")
                    }
                    if outcome.trashCount > 0 {
                        Label("\(outcome.trashCount) in the Trash. They stay there until you empty it and can be put back; the space is freed when the Trash is emptied.",
                              systemImage: "trash")
                    }
                }

                if !outcome.result.failures.isEmpty {
                    Section("Not moved") {
                        ForEach(outcome.result.failures, id: \.item.location) { failure in
                            VStack(alignment: .leading) {
                                MediaRow(item: failure.item)
                                Text(failure.reason.description).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                if let url = outcome.logURL {
                    Section("Decision log") {
                        Text("Saved to \(url.path)").font(.caption).textSelection(.enabled)
                    }
                } else if let error = outcome.logError {
                    Section("Decision log") {
                        Label("Couldn't save the decision log: \(error)", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }
            }
            .navigationTitle("Done")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onDone)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 360)
        #endif
    }
}

extension TrashResult.FailureReason {
    var description: String {
        switch self {
        case .notFound: return "It is no longer in the library."
        case let .systemError(message): return message
        }
    }
}
