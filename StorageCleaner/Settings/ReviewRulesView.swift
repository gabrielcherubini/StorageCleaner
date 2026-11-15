import StorageCleanerCore
import SwiftUI

/// Lets the user guide the category reviews: how strict each category is, whether its
/// "Likely to delete" items start selected, and a few simple date rules. Changes apply to the
/// current results right away. Protected items are never pre-selected whatever is set here.
struct ReviewRulesView: View {
    @Environment(ScanCoordinator.self) private var scanner
    /// Shown first when opened from a category screen.
    let focus: CleanupCategory?

    private static let monthChoices = [1, 3, 6, 12, 24, 36]
    private static let dayChoices = [7, 14, 30, 60, 90, 180, 365]

    private var categories: [CleanupCategory] {
        guard let focus else { return CleanupCategory.classified }
        return [focus] + CleanupCategory.classified.filter { $0 != focus }
    }

    var body: some View {
        Form {
            Section {
                Text("Every item gets a confidence score for its category. Items at or above the category’s threshold are listed under “Likely to delete”; the rest under “Likely to keep”. Nothing is moved until you review and confirm.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Label("Favorites, shared and edited items are never pre-selected.", systemImage: "lock.fill")
                    .font(.callout)
            }

            ForEach(categories, id: \.self) { category in
                Section {
                    Picker("Strictness", selection: strictness(category)) {
                        ForEach(Strictness.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Text(thresholdNote(category))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Toggle("Pre-select “Likely to delete”", isOn: preselect(category))
                    rules(for: category)
                } header: {
                    Label(category.title, systemImage: category.symbolName)
                }
            }

            Section {
                Toggle("Pre-select extra copies", isOn: preselect(.duplicates))
            } header: {
                Label(CleanupCategory.duplicates.title, systemImage: CleanupCategory.duplicates.symbolName)
            } footer: {
                Text("The suggested keeper of each group is never pre-selected.")
            }

            Section {
                Button("Restore Defaults") { scanner.setReviewPreferences(.default) }
                    .disabled(scanner.reviewPreferences == .default)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Review Rules")
    }

    @ViewBuilder
    private func rules(for category: CleanupCategory) -> some View {
        switch category {
        case .receipts:
            Toggle("Always keep recent receipts", isOn: Binding(
                get: { scanner.reviewPreferences.keepReceiptsNewerThanMonths != nil },
                set: { on in update { $0.keepReceiptsNewerThanMonths = on ? 6 : nil } }
            ))
            if let months = scanner.reviewPreferences.keepReceiptsNewerThanMonths {
                Picker("Newer than", selection: Binding(
                    get: { months },
                    set: { value in update { $0.keepReceiptsNewerThanMonths = value } }
                )) {
                    ForEach(Self.monthChoices, id: \.self) { Text($0 == 1 ? "1 month" : "\($0) months").tag($0) }
                }
            }
        case .screenshots:
            Toggle("Old screenshots are likely to delete", isOn: Binding(
                get: { scanner.reviewPreferences.screenshotsOlderThanDays != nil },
                set: { on in update { $0.screenshotsOlderThanDays = on ? 30 : nil } }
            ))
            if let days = scanner.reviewPreferences.screenshotsOlderThanDays {
                Picker("Older than", selection: Binding(
                    get: { days },
                    set: { value in update { $0.screenshotsOlderThanDays = value } }
                )) {
                    ForEach(Self.dayChoices, id: \.self) { Text("\($0) days").tag($0) }
                }
            }
        default:
            EmptyView()
        }
    }

    private func thresholdNote(_ category: CleanupCategory) -> String {
        let threshold = scanner.reviewPreferences.threshold(for: category)
            .formatted(.percent.precision(.fractionLength(0)))
        switch scanner.reviewPreferences.strictness(for: category) {
        case .conservative: return "Only very confident matches: \(threshold) or more."
        case .balanced: return "Likely to delete at \(threshold) confidence or more."
        case .aggressive: return "Also less certain matches: \(threshold) or more. Review before confirming."
        }
    }

    private func strictness(_ category: CleanupCategory) -> Binding<Strictness> {
        Binding(
            get: { scanner.reviewPreferences.strictness(for: category) },
            set: { value in update { $0.strictness[category] = value } }
        )
    }

    private func preselect(_ category: CleanupCategory) -> Binding<Bool> {
        Binding(
            get: { scanner.reviewPreferences.preselects(category) },
            set: { value in update { $0.preselect[category] = value } }
        )
    }

    private func update(_ change: (inout ReviewPreferences) -> Void) {
        var preferences = scanner.reviewPreferences
        change(&preferences)
        scanner.setReviewPreferences(preferences)
    }
}
