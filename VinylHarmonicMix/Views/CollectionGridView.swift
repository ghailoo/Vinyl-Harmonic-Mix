import SwiftUI
import SwiftData

enum CollectionSort: String, CaseIterable, Identifiable {
    case artistAsc  = "Artist (A → Z)"
    case artistDesc = "Artist (Z → A)"
    case titleAsc   = "Title (A → Z)"
    case titleDesc  = "Title (Z → A)"
    case yearDesc   = "Year (newest first)"
    case yearAsc    = "Year (oldest first)"
    case addedDesc  = "Recently added"
    case addedAsc   = "Added (oldest first)"
    case ratingDesc = "Rating (highest first)"
    case labelAsc   = "Label (A → Z)"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .artistAsc, .artistDesc:   return "person"
        case .titleAsc, .titleDesc:     return "textformat"
        case .yearDesc, .yearAsc:       return "calendar"
        case .addedDesc, .addedAsc:     return "clock"
        case .ratingDesc:               return "star"
        case .labelAsc:                 return "tag"
        }
    }
}

enum CollectionFilter: String, CaseIterable, Identifiable {
    case all       = "All"
    case matched   = "Matched"
    case notFound  = "Not found"
    case failed    = "Failed"
    case unscanned = "Unscanned"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .all:      return "circle.grid.2x2"
        case .matched:  return "checkmark.seal.fill"
        case .notFound: return "questionmark.circle"
        case .failed:   return "exclamationmark.triangle"
        case .unscanned: return "circle.dotted"
        }
    }
}

struct CollectionGridView: View {
    @Environment(CollectionViewModel.self) private var viewModel
    @Environment(MBIDScanCoordinator.self) private var scanCoordinator
    @Environment(\.modelContext) private var modelContext

    @Query private var allEntities: [CollectionItemEntity]

    @State private var searchQuery = ""
    @State private var selectedItem: CollectionItem?
    @State private var showRescanAlert = false
    @State private var activeFilter: CollectionFilter = .all
    @State private var activeSort: CollectionSort = .yearDesc

    private let columns = [GridItem(.adaptive(minimum: 160, maximum: 200), spacing: 16)]

    var body: some View {
        VStack(spacing: 0) {
            if scanCoordinator.shouldShowPanel {
                MBIDScanResultsView(coordinator: scanCoordinator) { filter in
                    activeFilter = filter
                    scanCoordinator.dismissPanel()
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 12)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
            if viewModel.items.isEmpty {
                emptyState
            } else if displayedItems.isEmpty && activeFilter != .all {
                filteredEmptyState
            } else {
                gridContent
                    .sheet(item: $selectedItem) { item in
                        CollectionDetailView(item: item)
                    }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: scanCoordinator.shouldShowPanel)
        .animation(.easeInOut(duration: 0.2), value: activeFilter)
        .animation(.easeInOut(duration: 0.2), value: activeSort)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                            .font(.system(size: 13))
                        TextField("Search artist, title, year…", text: $searchQuery)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .frame(width: 240, height: 24)
                    .background(Capsule().fill(Color.secondary.opacity(0.12)))
                    .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.2), lineWidth: 0.5))
                sortButton
                filterButton
                scanButton
                Button {
                    Task { await viewModel.importCollection() }
                } label: {
                    Label("Re-import from Discogs", systemImage: "arrow.down.circle")
                }
                .help("Re-import from Discogs")
            }
        }
        .alert("Rescan All Releases?", isPresented: $showRescanAlert) {
            Button("Rescan", role: .destructive) { scanCoordinator.startRescan() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will clear all existing MusicBrainz matches and re-scan every release.")
        }
    }

    // MARK: - Sort button

    private var sortButton: some View {
        Menu {
            ForEach(CollectionSort.allCases) { sort in
                Button {
                    activeSort = sort
                } label: {
                    HStack {
                        Image(systemName: sort.icon)
                        Text(sort.rawValue)
                        if activeSort == sort {
                            Spacer()
                            Image(systemName: "checkmark")
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: activeSort.icon)
                    .font(.system(size: 12, weight: .semibold))
                Text(activeSort.rawValue)
                    .font(.system(size: 13))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color.secondary.opacity(0.12)))
            .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.2), lineWidth: 0.5))
            .foregroundStyle(Color.primary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
    }

    // MARK: - Filter button

    private var filterButton: some View {
        Menu {
            ForEach(CollectionFilter.allCases) { filter in
                Button {
                    activeFilter = filter
                } label: {
                    HStack {
                        Image(systemName: filter.icon)
                        Text(filter.rawValue)
                        Spacer()
                        Text("\(filterCount(for: filter))")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: activeFilter.icon)
                    .font(.system(size: 12, weight: .semibold))
                Text("\(activeFilter.rawValue) (\(filterCount(for: activeFilter)))")
                    .font(.system(size: 13))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule()
                    .fill(activeFilter == .all
                          ? Color.secondary.opacity(0.12)
                          : Color.accentColor.opacity(0.15))
            )
            .overlay(
                Capsule()
                    .strokeBorder(
                        activeFilter == .all
                            ? Color.secondary.opacity(0.2)
                            : Color.accentColor.opacity(0.3),
                        lineWidth: 0.5
                    )
            )
            .foregroundStyle(activeFilter == .all ? Color.primary : Color.accentColor)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
    }

    private func filterCount(for filter: CollectionFilter) -> Int {
        switch filter {
        case .all:      return viewModel.items.count
        case .matched:  return allEntities.filter { $0.mbidScanState == "matched" || $0.mbidScanState == "matchedViaSearch" }.count
        case .notFound: return allEntities.filter { $0.mbidScanState == "notFound" }.count
        case .failed:   return allEntities.filter { $0.mbidScanState == "failed" }.count
        case .unscanned: return allEntities.filter { $0.mbidScanState == "unscanned" }.count
        }
    }

    private var matchedInstanceIds: Set<Int> {
        let matched = allEntities.filter {
            $0.mbidScanState == "matched" || $0.mbidScanState == "matchedViaSearch"
        }
        return Set(matched.map { $0.instanceId })
    }

    // MARK: - Scan toolbar button

    private var scanButton: some View {
        let unscanned = scanCoordinator.unscannedCount
        let notFound = scanCoordinator.notFoundCount
        let isActive: Bool = {
            switch scanCoordinator.phase {
            case .scanning, .paused: return true
            default: return false
            }
        }()
        let badgeCount = unscanned > 0 ? unscanned : notFound

        return Menu {
            Button {
                scanCoordinator.start()
            } label: {
                Label("Scan unscanned (\(unscanned))", systemImage: "magnifyingglass")
            }
            .disabled(unscanned == 0 || isActive)

            Button {
                print("🔘 [1] Retry notFound menu item tapped")
                print("🔘 [1a] Current notFoundCount = \(scanCoordinator.notFoundCount)")
                print("🔘 [1b] Current phase = \(scanCoordinator.phase)")
                scanCoordinator.startSearchScan()
                print("🔘 [1c] After calling startSearchScan(), phase = \(scanCoordinator.phase)")
            } label: {
                Label("Retry notFound (\(notFound))", systemImage: "arrow.clockwise.circle")
            }
            .disabled(notFound == 0 || isActive)

            Divider()

            Button(role: .destructive) {
                showRescanAlert = true
            } label: {
                Label("Rescan everything…", systemImage: "arrow.counterclockwise")
            }
            .disabled(isActive)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "music.note.list")
                if badgeCount > 0 {
                    Text("\(badgeCount)")
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.2))
                        .cornerRadius(4)
                }
            }
        }
        .help("Scan MusicBrainz IDs")
    }

    // MARK: - Grid

    private var gridContent: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 20) {
                ForEach(displayedItems) { item in
                    Button { selectedItem = item } label: {
                        CollectionCardView(item: item, hasMBID: matchedInstanceIds.contains(item.id))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var displayedItems: [CollectionItem] {
        var items = viewModel.items

        if activeFilter != .all {
            let matchingIds: Set<Int>
            switch activeFilter {
            case .all:
                matchingIds = []
            case .matched:
                matchingIds = Set(allEntities.filter { $0.mbidScanState == "matched" || $0.mbidScanState == "matchedViaSearch" }.map(\.instanceId))
            case .notFound:
                matchingIds = Set(allEntities.filter { $0.mbidScanState == "notFound" }.map(\.instanceId))
            case .failed:
                matchingIds = Set(allEntities.filter { $0.mbidScanState == "failed" }.map(\.instanceId))
            case .unscanned:
                matchingIds = Set(allEntities.filter { $0.mbidScanState == "unscanned" }.map(\.instanceId))
            }
            items = items.filter { matchingIds.contains($0.id) }
        }

        if !searchQuery.isEmpty {
            let q = searchQuery.lowercased()
            items = items.filter { item in
                item.basicInformation.title.lowercased().contains(q) ||
                item.basicInformation.artists.map(\.name).joined(separator: " & ").lowercased().contains(q) ||
                String(item.basicInformation.year).contains(q)
            }
        }

        items.sort { lhs, rhs in
            switch activeSort {
            case .artistAsc:
                return artistKey(lhs).localizedCaseInsensitiveCompare(artistKey(rhs)) == .orderedAscending
            case .artistDesc:
                return artistKey(lhs).localizedCaseInsensitiveCompare(artistKey(rhs)) == .orderedDescending
            case .titleAsc:
                return lhs.basicInformation.title.localizedCaseInsensitiveCompare(rhs.basicInformation.title) == .orderedAscending
            case .titleDesc:
                return lhs.basicInformation.title.localizedCaseInsensitiveCompare(rhs.basicInformation.title) == .orderedDescending
            case .yearDesc:
                let l = lhs.basicInformation.year, r = rhs.basicInformation.year
                if l == 0 && r == 0 { return false }
                if l == 0 { return false }
                if r == 0 { return true }
                return l > r
            case .yearAsc:
                let l = lhs.basicInformation.year, r = rhs.basicInformation.year
                if l == 0 && r == 0 { return false }
                if l == 0 { return false }
                if r == 0 { return true }
                return l < r
            case .addedDesc:
                return lhs.dateAdded > rhs.dateAdded
            case .addedAsc:
                return lhs.dateAdded < rhs.dateAdded
            case .ratingDesc:
                return lhs.rating > rhs.rating
            case .labelAsc:
                return labelKey(lhs).localizedCaseInsensitiveCompare(labelKey(rhs)) == .orderedAscending
            }
        }

        return items
    }

    private func artistKey(_ item: CollectionItem) -> String {
        item.basicInformation.artists.first?.name ?? ""
    }

    private func labelKey(_ item: CollectionItem) -> String {
        item.basicInformation.labels.first?.name ?? ""
    }

    private var filteredEmptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("No releases match the current filter.")
                .foregroundStyle(.secondary)
            Button("Clear filter") {
                activeFilter = .all
            }
            .buttonStyle(.bordered)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 24) {
            Spacer()
            switch viewModel.phase {
            case .idle, .loaded:
                Image(systemName: "record.circle")
                    .font(.system(size: 64))
                    .foregroundStyle(.secondary)
                Text("Your vinyl collection will appear here.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button {
                    Task { await viewModel.importCollection() }
                } label: {
                    Label("Import Collection", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!viewModel.isConfigured)
            case .loading(let progress):
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 300)
                Text(progressLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                Button {
                    Task { await viewModel.importCollection() }
                } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!viewModel.isConfigured)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var progressLabel: String {
        guard viewModel.totalPages > 0 else { return "Starting import…" }
        return "Importing page \(viewModel.currentPage) of \(viewModel.totalPages)"
    }
}
