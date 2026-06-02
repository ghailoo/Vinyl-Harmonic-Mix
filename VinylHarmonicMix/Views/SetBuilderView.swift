import SwiftUI
import SwiftData

struct SetBuilderView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AudioPlaybackController.self) private var playback
    @Environment(CollectionViewModel.self) private var viewModel

    @Query private var allCollectionEntities: [CollectionItemEntity]
    @Query private var allTrackEntities: [TrackEntity]
    @Query private var allFeatures: [RecordingFeaturesEntity]
    @Query private var allSets: [SetlistEntity]

    // State — Current Track is the user's focus
    @State private var currentTrack: MixTrack? = nil

    // State — pool/setlist management (filled in later steps)
    @AppStorage("setBuilderActiveSetID") private var activeSetID: String = ""
    @State private var activeSet: SetlistEntity? = nil

    // Harmonic strip controls
    @AppStorage("setBuilderBpmTolerancePct") private var bpmTolerancePct: Double = 5.0
    @State private var visibleGroups: Set<HarmonicGroup> = Set(HarmonicGroup.allCases)

    // Grid state
    @State private var featuresByMBID: [String: RecordingFeaturesEntity] = [:]
    @State private var coverageByInstanceId: [Int: (covered: Int, total: Int, localCovered: Int)] = [:]
    @State private var filePathToInstanceId: [String: Int] = [:]
    @State private var playingInstanceId: Int? = nil
    @State private var searchQuery = ""
    @State private var activeFilter: CollectionFilter = .all
    @State private var activeSort: CollectionSort = .yearDesc
    @AppStorage("collectionGridCardSize") private var cardSize: Double = 0.25

    // Sheet state
    @State private var selectedItem: CollectionItem? = nil

    private var gridColumns: [GridItem] {
        let minWidth = 120.0 + cardSize * 160.0
        return [GridItem(.adaptive(minimum: minWidth, maximum: minWidth + 40), spacing: 16)]
    }

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar placeholder — filled in step 5
            HStack {
                Text("Set Builder").font(.headline)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            // Current Track section — filled in step 3
            VStack {
                if currentTrack == nil {
                    Text("Tap a track in your collection below to begin")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Text("Current Track placeholder")
                }
            }
            .frame(height: 120)

            Divider()

            // Harmonic strip section — filled in step 4
            VStack {
                if currentTrack == nil {
                    Color.clear
                } else {
                    Text("Compatible tracks placeholder")
                }
            }
            .frame(height: 220)

            Divider()

            // Collection grid section
            gridControlsRow
            Divider()
            collectionGrid
        }
        .onAppear {
            rebuildFeaturesLookup()
            rebuildCoverageLookup()
            if activeSet == nil, !activeSetID.isEmpty {
                activeSet = allSets.first { $0.id == activeSetID }
                if activeSet == nil { activeSetID = "" }
            }
        }
        .onChange(of: allFeatures.count) { _, _ in
            rebuildFeaturesLookup()
            rebuildCoverageLookup()
        }
        .onChange(of: allTrackEntities.count) { _, _ in
            rebuildCoverageLookup()
        }
        .onChange(of: playback.currentFilePath) { _, newPath in
            playingInstanceId = newPath.flatMap { filePathToInstanceId[$0] }
        }
        .sheet(item: $selectedItem) { item in
            CollectionDetailView(item: item, onPromoteToCurrent: { track in
                handleTrackPick(track)
            })
        }
    }

    // MARK: - Track pick handler

    private func handleTrackPick(_ track: MixTrack) {
        currentTrack = track
    }

    // MARK: - Grid controls row

    private var gridControlsRow: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                TextField("Search artist, title, year…", text: $searchQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                if !searchQuery.isEmpty {
                    Button { searchQuery = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(Color.secondary.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: 280)
            .background(Capsule().fill(Color.secondary.opacity(0.10)))
            .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.2), lineWidth: 0.5))

            HStack(spacing: 4) {
                Image(systemName: "square.grid.3x3")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Slider(value: $cardSize, in: 0...1)
                    .frame(width: 64)
                    .controlSize(.mini)
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
            }

            sortButton
            filterButton
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Color.secondary.opacity(0.03))
    }

    // MARK: - Collection grid

    @ViewBuilder
    private var collectionGrid: some View {
        if viewModel.items.isEmpty {
            emptyState
        } else if displayedItems.isEmpty && activeFilter != .all {
            filteredEmptyState
        } else {
            ScrollView {
                LazyVGrid(columns: gridColumns, spacing: 20) {
                    ForEach(displayedItems) { item in
                        Button {
                            selectedItem = item
                        } label: {
                            CollectionCardView(
                                item: item,
                                hasMBID: matchedInstanceIds.contains(item.id),
                                covered: coverageByInstanceId[item.id]?.covered ?? 0,
                                total: coverageByInstanceId[item.id]?.total ?? 0,
                                localCovered: coverageByInstanceId[item.id]?.localCovered ?? 0,
                                isActive: playingInstanceId == item.id
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Sort button

    private var sortButton: some View {
        Menu {
            ForEach(CollectionSort.allCases) { sort in
                Button { activeSort = sort } label: {
                    HStack {
                        Image(systemName: sort.icon)
                        Text(sort.rawValue)
                        if activeSort == sort {
                            Spacer()
                            Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: activeSort.icon).font(.system(size: 12, weight: .semibold))
                Text(activeSort.rawValue).font(.system(size: 13))
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
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
                Button { activeFilter = filter } label: {
                    HStack {
                        Image(systemName: filter.icon)
                        Text(filter.rawValue)
                        Spacer()
                        Text("\(filterCount(for: filter))").monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: activeFilter.icon).font(.system(size: 12, weight: .semibold))
                Text("\(activeFilter.rawValue) (\(filterCount(for: activeFilter)))").font(.system(size: 13))
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Capsule().fill(activeFilter == .all
                ? Color.secondary.opacity(0.12)
                : Color.accentColor.opacity(0.15)))
            .overlay(Capsule().strokeBorder(activeFilter == .all
                ? Color.secondary.opacity(0.2)
                : Color.accentColor.opacity(0.3), lineWidth: 0.5))
            .foregroundStyle(activeFilter == .all ? Color.primary : Color.accentColor)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
    }

    // MARK: - Empty states

    private var filteredEmptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: 48)).foregroundStyle(.secondary)
            Text("No releases match the current filter.").foregroundStyle(.secondary)
            Button("Clear filter") { activeFilter = .all }.buttonStyle(.bordered)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "record.circle").font(.system(size: 48)).foregroundStyle(.secondary)
            Text("Your collection will appear here.").foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Lookup rebuilds

    private func rebuildFeaturesLookup() {
        var d: [String: RecordingFeaturesEntity] = [:]
        d.reserveCapacity(allFeatures.count)
        for f in allFeatures { d[f.recordingMBID] = f }
        featuresByMBID = d
    }

    private func rebuildCoverageLookup() {
        guard !allTrackEntities.isEmpty else { coverageByInstanceId = [:]; return }
        var totals: [Int: Int] = [:]
        var coveredCounts: [Int: Int] = [:]
        var localCounts: [Int: Int] = [:]
        var fpToId: [String: Int] = [:]
        fpToId.reserveCapacity(allTrackEntities.count)
        for track in allTrackEntities {
            guard let id = track.collectionItem?.instanceId else { continue }
            totals[id, default: 0] += 1
            let hasEffectiveBpm = track.effectiveBpm != nil
            let hasLocalSource  = track.featureSource == .local
            let f = featuresByMBID[track.recordingMBID]
            let hasAbBpm = f?.bpm != nil && f?.camelotCode != nil
            if hasEffectiveBpm || hasAbBpm { coveredCounts[id, default: 0] += 1 }
            if hasLocalSource              { localCounts[id, default: 0] += 1 }
            if let fp = track.primaryLocalFilePath, !fp.isEmpty { fpToId[fp] = id }
        }
        coverageByInstanceId = Dictionary(uniqueKeysWithValues: totals.keys.map { id in
            (id, (covered: coveredCounts[id] ?? 0, total: totals[id]!, localCovered: localCounts[id] ?? 0))
        })
        filePathToInstanceId = fpToId
        playingInstanceId = playback.currentFilePath.flatMap { fpToId[$0] }
    }

    // MARK: - Computed helpers

    private var matchedInstanceIds: Set<Int> {
        Set(allCollectionEntities.filter {
            $0.mbidScanState == "matched" ||
            $0.mbidScanState == "matchedViaSearch" ||
            $0.mbidScanState == "matchedManually"
        }.map(\.instanceId))
    }

    private func filterCount(for filter: CollectionFilter) -> Int {
        switch filter {
        case .all:       return viewModel.items.count
        case .matched:   return allCollectionEntities.filter {
            $0.mbidScanState == "matched" ||
            $0.mbidScanState == "matchedViaSearch" ||
            $0.mbidScanState == "matchedManually"
        }.count
        case .notFound:  return allCollectionEntities.filter { $0.mbidScanState == "notFound" }.count
        case .failed:    return allCollectionEntities.filter { $0.mbidScanState == "failed" }.count
        case .unscanned: return allCollectionEntities.filter { $0.mbidScanState == "unscanned" }.count
        }
    }

    private var displayedItems: [CollectionItem] {
        var items = viewModel.items

        if activeFilter != .all {
            let matchingIds: Set<Int>
            switch activeFilter {
            case .all:       matchingIds = []
            case .matched:
                matchingIds = Set(allCollectionEntities.filter {
                    $0.mbidScanState == "matched" ||
                    $0.mbidScanState == "matchedViaSearch" ||
                    $0.mbidScanState == "matchedManually"
                }.map(\.instanceId))
            case .notFound:
                matchingIds = Set(allCollectionEntities.filter { $0.mbidScanState == "notFound" }.map(\.instanceId))
            case .failed:
                matchingIds = Set(allCollectionEntities.filter { $0.mbidScanState == "failed" }.map(\.instanceId))
            case .unscanned:
                matchingIds = Set(allCollectionEntities.filter { $0.mbidScanState == "unscanned" }.map(\.instanceId))
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
            case .artistAsc:  return artistKey(lhs).localizedCaseInsensitiveCompare(artistKey(rhs)) == .orderedAscending
            case .artistDesc: return artistKey(lhs).localizedCaseInsensitiveCompare(artistKey(rhs)) == .orderedDescending
            case .titleAsc:   return lhs.basicInformation.title.localizedCaseInsensitiveCompare(rhs.basicInformation.title) == .orderedAscending
            case .titleDesc:  return lhs.basicInformation.title.localizedCaseInsensitiveCompare(rhs.basicInformation.title) == .orderedDescending
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
            case .addedDesc:  return lhs.dateAdded > rhs.dateAdded
            case .addedAsc:   return lhs.dateAdded < rhs.dateAdded
            case .ratingDesc: return lhs.rating > rhs.rating
            case .labelAsc:   return labelKey(lhs).localizedCaseInsensitiveCompare(labelKey(rhs)) == .orderedAscending
            }
        }
        return items
    }

    private func artistKey(_ item: CollectionItem) -> String { item.basicInformation.artists.first?.name ?? "" }
    private func labelKey(_ item: CollectionItem) -> String  { item.basicInformation.labels.first?.name ?? "" }
}
