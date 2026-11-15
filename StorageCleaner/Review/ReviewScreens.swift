import StorageCleanerCore
import SwiftUI

enum ReviewRoute: Hashable {
    case duplicates
    case category(CleanupCategory)
    case largeFiles
    case heaviest
    case rules
}

struct ReviewDestination: View {
    @Environment(ScanCoordinator.self) private var scanner
    let route: ReviewRoute

    var body: some View {
        content.id(route)
    }

    @ViewBuilder
    private var content: some View {
        switch route {
        case .duplicates:
            DuplicatesReviewScreen()
        case let .category(category):
            let review = scanner.classifications?.reviews.first { $0.category == category }
            let preferences = scanner.reviewPreferences
            GridReviewScreen(
                title: category.title,
                explanation: category.explanation,
                sections: [
                    ReviewSection(id: "delete", title: "Likely to delete", tint: .primary,
                                  entries: review?.likelyToDelete.map { ReviewEntry($0, preferences: preferences) } ?? []),
                    ReviewSection(id: "keep", title: "Likely to keep", tint: .primary,
                                  entries: review?.likelyToKeep.map { ReviewEntry($0, preferences: preferences) } ?? []),
                ],
                preselected: review?.preselectedItems ?? [],
                rulesCategory: category
            )
        case .largeFiles:
            LoadedItemsReviewScreen(title: CleanupCategory.largeFiles.title,
                                    explanation: CleanupCategory.largeFiles.explanation,
                                    reason: .largeFile) { await scanner.largeFiles() }
        case .heaviest:
            LoadedItemsReviewScreen(title: "Heaviest items",
                                    explanation: "Everything StorageCleaner indexed, largest first. Nothing is pre-selected.",
                                    reason: nil) { await scanner.heaviestItems() }
        case .rules:
            ReviewRulesView(focus: nil)
        }
    }
}

struct ReviewSection: Identifiable {
    let id: String
    let title: String
    let tint: Color
    let entries: [ReviewEntry]
}

/// Items loaded from the index (large files, heaviest items); nothing starts selected.
private struct LoadedItemsReviewScreen: View {
    @Environment(ScanCoordinator.self) private var scanner
    let title: String
    let explanation: String
    let reason: DecisionReason?
    let load: @MainActor () async -> [MediaItem]

    @State private var items: [MediaItem]?

    var body: some View {
        Group {
            if let items {
                GridReviewScreen(
                    title: title,
                    explanation: explanation,
                    sections: [ReviewSection(id: "all", title: "Items", tint: .secondary,
                                             entries: items.map { ReviewEntry(item: $0, reason: reason) })],
                    preselected: []
                )
            } else {
                ProgressView("Loading…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .navigationTitle(title)
            }
        }
        .task(id: scanner.summary.itemCount) { items = await load() }
    }
}

/// Grid review for one category: sections (Likely to delete / Likely to keep), filters, bulk
/// select, per-item override, then the confirm sheet.
///
/// The screen's body never reads the selection; tiles and the selection bar do. Toggling an
/// item therefore doesn't rebuild the grid, and the scroll position stays put.
struct GridReviewScreen: View {
    @Environment(TrashCoordinator.self) private var trash
    let title: String
    let explanation: String
    let sections: [ReviewSection]
    let preselected: [MediaItem]
    /// The category whose review rules the toolbar button opens; `nil` hides the button.
    var rulesCategory: CleanupCategory?

    @State private var store = SelectionStore()
    @State private var filter = ReviewFilter()
    @State private var visibleSection = "all"
    @State private var pending: PendingTrash?
    @State private var outcome: TrashCoordinator.Outcome?
    @State private var bulkNote: String?
    @State private var viewer: ViewerRequest?
    @State private var showsRules = false

    private var allEntries: [ReviewEntry] { sections.flatMap(\.entries) }

    private func shown(_ section: ReviewSection) -> [ReviewEntry] {
        guard visibleSection == "all" || visibleSection == section.id else { return [] }
        return filter.apply(to: section.entries, item: \.item)
    }

    private var shownEntries: [ReviewEntry] { sections.flatMap(shown) }
    private var shownItems: [MediaItem] { shownEntries.map(\.item) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(explanation).font(.subheadline).foregroundStyle(.secondary)

                if sections.count > 1 {
                    Picker("Show", selection: $visibleSection) {
                        Text("All").tag("all")
                        ForEach(sections) { section in
                            Text("\(section.title) (\(section.entries.count))").tag(section.id)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                FilterBar(filter: $filter)

                if allEntries.isEmpty {
                    ContentUnavailableView("Nothing to review", systemImage: "checkmark.circle",
                                           description: Text("No items in this category right now."))
                } else if shownEntries.isEmpty {
                    ContentUnavailableView {
                        Label("No matching items", systemImage: "line.3.horizontal.decrease.circle")
                    } description: {
                        Text("Try a different size, date or kind filter.")
                    } actions: {
                        Button("Clear Filters") { filter = ReviewFilter(); visibleSection = "all" }
                    }
                }

                ForEach(sections) { section in
                    let entries = shown(section)
                    if !entries.isEmpty {
                        if sections.count > 1 {
                            HStack(alignment: .firstTextBaseline) {
                                Text(section.title).font(.headline).foregroundStyle(section.tint)
                                Text("\(entries.count)").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                                Spacer()
                                Text(formattedBytes(entries.map(\.item).totalByteSize))
                                    .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }
                        LazyVGrid(columns: Theme.gridColumns, spacing: 18) {
                            ForEach(entries) { entry in
                                SelectableTile(store: store, entry: entry) {
                                    viewer = ViewerRequest(entries: shownEntries, start: entry.id)
                                }
                            }
                        }
                    }
                }
            }
            .padding()
        }
        .navigationTitle(title)
        .toolbar {
            if rulesCategory != nil {
                ToolbarItem(placement: .primaryAction) {
                    Button("Review Rules", systemImage: "slider.horizontal.3") { showsRules = true }
                }
            }
        }
        .sheet(isPresented: $showsRules) {
            if let rulesCategory {
                NavigationStack {
                    ReviewRulesView(focus: rulesCategory)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) { Button("Done") { showsRules = false } }
                        }
                }
                #if os(macOS)
                .frame(minWidth: 460, minHeight: 520)
                #endif
            }
        }
        .safeAreaInset(edge: .bottom) {
            SelectionBar(
                store: store,
                allItems: allEntries.map(\.item),
                shownItems: shownItems,
                note: bulkNote,
                isBusy: trash.isTrashing,
                onSelectAll: {
                    let skipped = store.selectAll(shownItems)
                    bulkNote = skipped > 0 ? "\(skipped) favorite, shared or edited items were not selected." : nil
                },
                onDeselectAll: {
                    store.deselectAll(shownItems)
                    bulkNote = nil
                },
                onReview: reviewSelection
            )
        }
        .trashFlow(pending: $pending, outcome: $outcome) { moved in
            store.deselect(moved)
        }
        .mediaViewer($viewer, selection: store.binding)
        .onChange(of: Set(preselected.map(\.location)), initial: true) {
            store.seed(preselected)
        }
        #if DEBUG
        .task(id: allEntries.count) { await openDemoScreen() }
        #endif
    }

    private func reviewSelection() {
        let plan = store.selection.plan(from: allEntries.map(\.item))
        let reasons = Dictionary(allEntries.compactMap { entry in entry.reason.map { (entry.item.location, $0) } },
                                 uniquingKeysWith: { first, _ in first })
        pending = PendingTrash(plan: plan, reasons: reasons)
    }

    #if DEBUG
    private func openDemoScreen() async {
        guard !allEntries.isEmpty, viewer == nil, pending == nil else { return }
        try? await Task.sleep(for: .milliseconds(600))
        switch DemoMode.screen {
        case "viewer": if let first = allEntries.first { viewer = ViewerRequest(entries: allEntries, start: first.id) }
        case "confirm": if !store.selection.selected.isEmpty { reviewSelection() }
        default: break
        }
    }
    #endif
}

/// A tile that reads its own selection state, so a toggle re-renders just the tiles.
private struct SelectableTile: View {
    let store: SelectionStore
    let entry: ReviewEntry
    var badge: TileBadge?
    let onOpen: () -> Void

    var body: some View {
        MediaTile(entry: entry, isSelected: store.isSelected(entry.item), badge: badge,
                  onOpen: onOpen, onToggle: { store.toggle(entry.item) })
    }
}

/// Duplicate groups with the suggested keeper first; copies suggested for removal start selected.
struct DuplicatesReviewScreen: View {
    @Environment(ScanCoordinator.self) private var scanner
    @Environment(TrashCoordinator.self) private var trash

    @State private var store = SelectionStore()
    @State private var filter = ReviewFilter()
    @State private var pending: PendingTrash?
    @State private var outcome: TrashCoordinator.Outcome?
    @State private var bulkNote: String?
    @State private var viewer: ViewerRequest?

    private var groups: [DuplicateGroup] { scanner.duplicates?.groups ?? [] }

    private var preselected: [MediaItem] {
        scanner.reviewPreferences.preselects(.duplicates) ? groups.flatMap(\.suggestedForRemoval) : []
    }

    /// A group is shown when any of its items passes the filter.
    private var shownGroups: [DuplicateGroup] {
        let shown = groups.filter { group in group.items.contains { filter.includes($0) } }
        return filter.apply(to: shown, item: { group in
            group.items.max(by: { a, b in a.byteSize < b.byteSize }) ?? group.keeper
        })
    }

    var body: some View {
        List {
            Section {
                Text(CleanupCategory.duplicates.explanation).font(.callout).foregroundStyle(.secondary)
                FilterBar(filter: $filter)
            }
            if groups.isEmpty {
                ContentUnavailableView("No duplicates", systemImage: "checkmark.circle",
                                       description: Text("Run “Find Duplicates” on the dashboard."))
            }
            ForEach(shownGroups) { group in
                Section {
                    ScrollView(.horizontal) {
                        HStack(alignment: .top, spacing: 12) {
                            ForEach(group.items) { item in
                                SelectableTile(store: store, entry: ReviewEntry(duplicate: item, in: group),
                                               badge: item.location == group.keeper.location ? .keep : nil) {
                                    viewer = ViewerRequest(
                                        entries: group.items.map { ReviewEntry(duplicate: $0, in: group) },
                                        start: item.location)
                                }
                                .frame(width: 120)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    EmptiedGroupWarning(store: store, group: group)
                    NavigationLink("Compare side by side") {
                        DuplicateCompareView(group: group, selection: store.binding)
                    }
                } header: {
                    HStack {
                        Text("\(group.match.title) · \(group.items.count) copies")
                        Spacer()
                        Text("\(formattedBytes(group.reclaimableBytes)) reclaimable")
                    }
                }
            }
        }
        .navigationTitle("Duplicates")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu("Review Rules", systemImage: "slider.horizontal.3") {
                    Toggle("Pre-select extra copies", isOn: Binding(
                        get: { scanner.reviewPreferences.preselects(.duplicates) },
                        set: { var preferences = scanner.reviewPreferences
                               preferences.preselect[.duplicates] = $0
                               scanner.setReviewPreferences(preferences) }
                    ))
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            let items = groups.flatMap(\.items)
            let shownItems = shownGroups.flatMap(\.items)
            SelectionBar(
                store: store,
                allItems: items,
                shownItems: shownItems,
                selectAllTitle: "Select suggested",
                note: bulkNote,
                isBusy: trash.isTrashing,
                onSelectAll: {
                    store.selectAll(shownGroups.flatMap(\.suggestedForRemoval))
                    bulkNote = "Keepers and favorite, shared or edited copies were not selected."
                },
                onDeselectAll: {
                    store.deselectAll(shownItems)
                    bulkNote = nil
                },
                onReview: {
                    var reasons: [MediaLocation: DecisionReason] = [:]
                    for group in groups {
                        for item in group.items where reasons[item.location] == nil {
                            reasons[item.location] = .duplicate(of: group)
                        }
                    }
                    let emptied = groups.filter { $0.selectsEveryCopy(store.selection) }.count
                    pending = PendingTrash(
                        plan: store.selection.plan(from: items),
                        reasons: reasons,
                        warnings: emptied > 0 ? ["\(emptied) duplicate \(emptied == 1 ? "group loses" : "groups lose") every copy."] : []
                    )
                }
            )
        }
        .trashFlow(pending: $pending, outcome: $outcome) { moved in
            store.deselect(moved)
        }
        .mediaViewer($viewer, selection: store.binding)
        .onChange(of: Set(preselected.map(\.location)), initial: true) {
            store.seed(preselected)
        }
    }
}

private struct EmptiedGroupWarning: View {
    let store: SelectionStore
    let group: DuplicateGroup

    var body: some View {
        if group.selectsEveryCopy(store.selection) {
            Label("Every copy in this group is selected; none would be left.", systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.orange)
        }
    }
}

/// Side-by-side comparison of the copies in one duplicate group.
struct DuplicateCompareView: View {
    let group: DuplicateGroup
    @Binding var selection: ReviewSelection

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            HStack(alignment: .top, spacing: 16) {
                ForEach(group.items) { item in
                    VStack(alignment: .leading, spacing: 8) {
                        ThumbnailView(item: item, maxPixelSize: 900, contentMode: .fit)
                            .frame(width: 300, height: 300)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        status(for: item)
                        Text(item.filename ?? "Untitled").font(.headline).lineLimit(2)
                        details(for: item)
                        Toggle("Move to Trash", isOn: Binding(
                            get: { selection.isSelected(item) },
                            set: { if $0 != selection.isSelected(item) { selection.toggle(item) } }
                        ))
                    }
                    .frame(width: 300)
                }
            }
            .padding()
        }
        .navigationTitle(group.match.title)
    }

    @ViewBuilder
    private func status(for item: MediaItem) -> some View {
        if item.location == group.keeper.location {
            Label("Suggested keeper", systemImage: "star.fill").foregroundStyle(.green)
        } else if item.isProtected {
            Label("Protected: \(item.protectionNote ?? "")", systemImage: "lock.fill").foregroundStyle(.secondary)
        } else {
            Label("Suggested to remove", systemImage: "trash").foregroundStyle(.secondary)
        }
    }

    private func details(for item: MediaItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent("Size", value: formattedBytes(item.byteSize))
            if let dimensions = item.dimensionsText { LabeledContent("Resolution", value: dimensions) }
            if let duration = item.duration { LabeledContent("Duration", value: formattedDuration(duration)) }
            if let date = item.creationDate {
                LabeledContent("Created", value: date.formatted(date: .abbreviated, time: .shortened))
            }
            LabeledContent("Source", value: item.sourceName)
            if item.isLocallyAvailable == false { LabeledContent("Stored", value: "Only in iCloud") }
        }
        .font(.caption)
    }
}

/// Size, date, kind and sort filters.
struct FilterBar: View {
    @Binding var filter: ReviewFilter

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Menu {
                    Picker("Size", selection: $filter.size) {
                        ForEach(ReviewFilter.SizeBucket.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                } label: {
                    chip("Size: \(filter.size.title)", active: filter.size != .any)
                }
                Menu {
                    Picker("Date", selection: $filter.date) {
                        ForEach(ReviewFilter.DateBucket.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                } label: {
                    chip("Date: \(filter.date.title)", active: filter.date != .any)
                }
                Menu {
                    ForEach(MediaKind.allCases, id: \.self) { kind in
                        Toggle(kind.title, isOn: Binding(
                            get: { filter.kinds.contains(kind) },
                            set: { if $0 { filter.kinds.insert(kind) } else if filter.kinds.count > 1 { filter.kinds.remove(kind) } }
                        ))
                    }
                } label: {
                    chip(filter.kinds.count == MediaKind.allCases.count ? "All kinds"
                         : MediaKind.allCases.filter(filter.kinds.contains).map(\.title).joined(separator: ", "),
                         active: filter.kinds.count != MediaKind.allCases.count)
                }
                Menu {
                    Picker("Sort", selection: $filter.sort) {
                        ForEach(ReviewFilter.Sort.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                } label: {
                    chip(filter.sort.title, active: false)
                }
                if filter.isActive {
                    Button("Clear") { filter = ReviewFilter() }.font(.caption)
                }
            }
        }
    }

    private func chip(_ text: String, active: Bool) -> some View {
        Text(text)
            .font(.caption)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(active ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.12), in: Capsule())
    }
}

/// Bottom bar: selection count and size, bulk select, and the button that opens the confirm sheet.
struct SelectionBar: View {
    let store: SelectionStore
    let allItems: [MediaItem]
    let shownItems: [MediaItem]
    var selectAllTitle = "Select all shown"
    let note: String?
    let isBusy: Bool
    let onSelectAll: () -> Void
    let onDeselectAll: () -> Void
    let onReview: () -> Void

    var body: some View {
        let selected = allItems.filter(store.isSelected)
        let hidden = selected.count - shownItems.filter(store.isSelected).count
        VStack(alignment: .leading, spacing: 6) {
            if let note {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                VStack(alignment: .leading) {
                    Text("\(selected.count) selected · \(formattedBytes(selected.totalByteSize))").bold().monospacedDigit()
                    if hidden > 0 {
                        Text("\(hidden) selected items are hidden by filters").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Menu("Select") {
                    Button(selectAllTitle, action: onSelectAll)
                    Button("Deselect all shown", action: onDeselectAll)
                }
                .fixedSize()
                Button(role: .destructive, action: onReview) {
                    if isBusy {
                        ProgressView()
                    } else {
                        Text("Review & Move to Trash…")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(selected.isEmpty || isBusy)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 12)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

private struct TrashFlowModifier: ViewModifier {
    @Environment(TrashCoordinator.self) private var trash
    @Binding var pending: PendingTrash?
    @Binding var outcome: TrashCoordinator.Outcome?
    let onMoved: (Set<MediaLocation>) -> Void

    func body(content: Content) -> some View {
        content
            .sheet(item: $pending) { request in
                ConfirmTrashSheet(pending: request) { confirmation in
                    pending = nil
                    Task {
                        if let result = await trash.moveToTrash(request.plan, confirmation: confirmation, reasons: request.reasons) {
                            onMoved(Set(result.result.moved.map(\.item.location)))
                            outcome = result
                        }
                    }
                } onCancel: {
                    pending = nil
                }
            }
            .sheet(item: $outcome) { result in
                TrashSummarySheet(outcome: result) { outcome = nil }
            }
    }
}

extension View {
    /// Confirm sheet, then `TrashService` via `TrashCoordinator`, then the post-trash summary.
    func trashFlow(pending: Binding<PendingTrash?>, outcome: Binding<TrashCoordinator.Outcome?>,
                   onMoved: @escaping (Set<MediaLocation>) -> Void) -> some View {
        modifier(TrashFlowModifier(pending: pending, outcome: outcome, onMoved: onMoved))
    }
}

extension ReviewFilter.SizeBucket {
    var title: String {
        switch self {
        case .any: return "Any"
        case .atLeast1MB: return "1 MB+"
        case .atLeast10MB: return "10 MB+"
        case .atLeast50MB: return "50 MB+"
        case .atLeast100MB: return "100 MB+"
        case .atLeast1GB: return "1 GB+"
        }
    }
}

extension ReviewFilter.DateBucket {
    var title: String {
        switch self {
        case .any: return "Any"
        case .lastMonth: return "Last 30 days"
        case .lastYear: return "Last year"
        case .olderThanOneYear: return "Older than 1 year"
        case .olderThanThreeYears: return "Older than 3 years"
        }
    }
}

extension ReviewFilter.Sort {
    var title: String {
        switch self {
        case .largestFirst: return "Largest first"
        case .newestFirst: return "Newest first"
        case .oldestFirst: return "Oldest first"
        }
    }
}
