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
    @Environment(RecordingsScanCoordinator.self) private var recordingsCoordinator
    @Environment(AudioFeaturesScanCoordinator.self) private var audioFeaturesCoordinator
    @Environment(AudioPlaybackController.self) private var playback
    @Environment(\.modelContext) private var modelContext

    @Query private var allEntities: [CollectionItemEntity]
    @Query private var allTrackEntities: [TrackEntity]
    @Query private var allFeatures: [RecordingFeaturesEntity]
    @Query(filter: #Predicate<LocalFileEntity> { $0.bpm > 0 })
    private var analyzedLocalFiles: [LocalFileEntity]

    @State private var featuresByMBID: [String: RecordingFeaturesEntity] = [:]
    @State private var coverageByInstanceId: [Int: (covered: Int, total: Int, localCovered: Int)] = [:]
    @State private var filePathToInstanceId: [String: Int] = [:]
    @State private var playingInstanceId: Int? = nil

    @State private var searchQuery = ""
    @State private var selectedItem: CollectionItem?
    @State private var showRescanAlert = false
    @State private var showRefetchAlert = false
    @State private var showRescanAudioAlert = false
    @State private var showSyncSheet = false
    @State private var activeFilter: CollectionFilter = .all
    @State private var activeSort: CollectionSort = .yearDesc

    // 0 → 120pt minimum (many small cards), 1 → 280pt (few large cards).
    // Default 0.25 reproduces the previous 160pt minimum.
    @AppStorage("collectionGridCardSize") private var cardSize: Double = 0.25

    private var gridColumns: [GridItem] {
        let minWidth = 120.0 + cardSize * 160.0
        return [GridItem(.adaptive(minimum: minWidth, maximum: minWidth + 40), spacing: 16)]
    }

    var body: some View {
        VStack(spacing: 0) {
            if audioFeaturesCoordinator.shouldShowPanel {
                AudioFeaturesScanResultsView(
                    coordinator: audioFeaturesCoordinator,
                    onOpenItem: { instanceId in
                        selectedItem = viewModel.items.first { $0.id == instanceId }
                    }
                )
                .padding(.horizontal, 24)
                .padding(.top, 12)
                .padding(.bottom, 0)
                .frame(maxWidth: .infinity)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
            if recordingsCoordinator.shouldShowPanel {
                RecordingsScanResultsView(
                    coordinator: recordingsCoordinator,
                    onOpenItem: { instanceId in
                        selectedItem = viewModel.items.first { $0.id == instanceId }
                    }
                )
                .padding(.horizontal, 24)
                .padding(.top, 12)
                .padding(.bottom, 0)
                .frame(maxWidth: .infinity)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
            if scanCoordinator.shouldShowPanel {
                MBIDScanResultsView(
                    coordinator: scanCoordinator,
                    onFilterSelect: { filter in
                        activeFilter = filter
                        scanCoordinator.dismissPanel()
                    },
                    onOpenItem: { instanceId in
                        selectedItem = viewModel.items.first { $0.id == instanceId }
                    }
                )
                .padding(.horizontal, 24)
                .padding(.top, 12)
                .padding(.bottom, 12)
                .frame(maxWidth: .infinity)
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
        .animation(.easeInOut(duration: 0.25), value: audioFeaturesCoordinator.shouldShowPanel)
        .animation(.easeInOut(duration: 0.25), value: recordingsCoordinator.shouldShowPanel)
        .animation(.easeInOut(duration: 0.25), value: scanCoordinator.shouldShowPanel)
        .animation(.easeInOut(duration: 0.2), value: activeFilter)
        .animation(.easeInOut(duration: 0.2), value: activeSort)
        .onAppear {
            rebuildFeaturesLookup()
            rebuildCoverageLookup()
        }
        .onChange(of: allFeatures.count) { _, _ in
            rebuildFeaturesLookup()
            rebuildCoverageLookup()
        }
        .onChange(of: allTrackEntities.count) { _, _ in
            rebuildCoverageLookup()
        }
        .onChange(of: analyzedLocalFiles.count) { _, _ in
            rebuildCoverageLookup()
        }
        .onChange(of: playback.currentFilePath) { _, newPath in
            playingInstanceId = newPath.flatMap { filePathToInstanceId[$0] }
        }
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
                HStack(spacing: 4) {
                    Image(systemName: "square.grid.3x3")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    Slider(value: $cardSize, in: 0...1)
                        .frame(width: 72)
                        .controlSize(.mini)
                    Image(systemName: "square.grid.2x2")
                        .font(.system(size: 13))
                        .foregroundStyle(.tertiary)
                }
                sortButton
                fetchTracksButton
                scanAudioButton
                filterButton
                scanButton
                Button {
                    showSyncSheet = true
                } label: {
                    Label("Check for new releases", systemImage: "arrow.triangle.2.circlepath")
                }
                .help("Check Discogs for new releases and import only additions")
                .sheet(isPresented: $showSyncSheet) {
                    SyncCheckView()
                        .environment(viewModel)
                }
                Button {
                    Task { await viewModel.importCollection() }
                } label: {
                    Label("Re-import from Discogs", systemImage: "arrow.down.circle")
                }
                .help("Re-import from Discogs (full wipe + reinsert)")
            }
        }
        .alert("Rescan All Releases?", isPresented: $showRescanAlert) {
            Button("Rescan", role: .destructive) { scanCoordinator.startRescan() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will clear all existing MusicBrainz matches and re-scan every release.")
        }
        .alert("Refetch all track recordings?", isPresented: $showRefetchAlert) {
            Button("Refetch", role: .destructive) { recordingsCoordinator.startRefetch() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will delete all stored recording MBIDs and re-fetch every matched release. Takes ~7–8 minutes.")
        }
        .alert("Rescan all audio features?", isPresented: $showRescanAudioAlert) {
            Button("Rescan", role: .destructive) { audioFeaturesCoordinator.rescanAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will delete all stored BPM/key data and re-query AcousticBrainz for every recording MBID. Takes ~3 minutes.")
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
        case .matched:  return allEntities.filter {
            $0.mbidScanState == "matched" || $0.mbidScanState == "matchedViaSearch" || $0.mbidScanState == "matchedManually"
        }.count
        case .notFound: return allEntities.filter { $0.mbidScanState == "notFound" }.count
        case .failed:   return allEntities.filter { $0.mbidScanState == "failed" }.count
        case .unscanned: return allEntities.filter { $0.mbidScanState == "unscanned" }.count
        }
    }

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
            // effectiveBpm covers both track-level LocalAudioFeaturesEntity and
            // file-level LocalFileEntity.bpm (via the linked localFiles relationship)
            let hasEffectiveBpm = track.effectiveBpm != nil
            let hasLocalSource  = track.featureSource == .local
            let f = featuresByMBID[track.recordingMBID]
            let hasAbBpm = f?.bpm != nil && f?.camelotCode != nil
            if hasEffectiveBpm || hasAbBpm {
                coveredCounts[id, default: 0] += 1
            }
            if hasLocalSource {
                localCounts[id, default: 0] += 1
            }
            if let fp = track.primaryLocalFilePath, !fp.isEmpty {
                fpToId[fp] = id
            }
        }
        coverageByInstanceId = Dictionary(uniqueKeysWithValues: totals.keys.map { id in
            (id, (covered: coveredCounts[id] ?? 0, total: totals[id]!, localCovered: localCounts[id] ?? 0))
        })
        filePathToInstanceId = fpToId
        playingInstanceId = playback.currentFilePath.flatMap { fpToId[$0] }
    }

    private var matchedInstanceIds: Set<Int> {
        let matched = allEntities.filter {
            $0.mbidScanState == "matched" || $0.mbidScanState == "matchedViaSearch" || $0.mbidScanState == "matchedManually"
        }
        return Set(matched.map { $0.instanceId })
    }

    // MARK: - Fetch tracks toolbar button

    private var fetchTracksButton: some View {
        let unscanned = recordingsCoordinator.unscannedWithMBIDCount
        let failed = recordingsCoordinator.failedCount
        let isActive: Bool = {
            switch recordingsCoordinator.phase {
            case .scanning, .paused: return true
            default: return false
            }
        }()
        let badgeCount = unscanned > 0 ? unscanned : failed

        return Menu {
            Button {
                recordingsCoordinator.start()
            } label: {
                Label("Fetch unscanned (\(unscanned))", systemImage: "waveform")
            }
            .disabled(unscanned == 0 || isActive)

            Button {
                recordingsCoordinator.start()
            } label: {
                Label("Retry failed (\(failed))", systemImage: "arrow.clockwise.circle")
            }
            .disabled(failed == 0 || isActive)

            Divider()

            Button(role: .destructive) {
                showRefetchAlert = true
            } label: {
                Label("Refetch all…", systemImage: "arrow.counterclockwise")
            }
            .disabled(isActive)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "music.note.list")
                    .font(.system(size: 12, weight: .semibold))
                Text("Fetch tracks")
                    .font(.system(size: 13))
                if badgeCount > 0 {
                    Text("\(badgeCount)")
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.2))
                        .cornerRadius(4)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color.secondary.opacity(0.12)))
            .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.2), lineWidth: 0.5))
            .foregroundStyle(Color.primary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .help("Fetch recording MBIDs from MusicBrainz")
    }

    // MARK: - Scan audio toolbar button

    private var scanAudioButton: some View {
        let unqueried = audioFeaturesCoordinator.unqueriedCount
        let missing = audioFeaturesCoordinator.missingBatchCount
        let isActive: Bool = {
            switch audioFeaturesCoordinator.phase {
            case .scanning, .paused: return true
            default: return false
            }
        }()
        let badgeCount = unqueried > 0 ? unqueried : missing

        let noBpm = audioFeaturesCoordinator.noBpmCount

        return Menu {
            Button {
                audioFeaturesCoordinator.start()
            } label: {
                Label("Scan unqueried (\(unqueried))", systemImage: "waveform.badge.magnifyingglass")
            }
            .disabled(unqueried == 0 || isActive)

            Button {
                audioFeaturesCoordinator.startEnrich()
            } label: {
                Label("Fill in BPM + key (\(noBpm))", systemImage: "music.quarternote.3")
            }
            .disabled(noBpm == 0 || isActive)

            Button {
                audioFeaturesCoordinator.refetchMissing()
            } label: {
                Label("Refetch missing (\(missing))", systemImage: "arrow.clockwise.circle")
            }
            .disabled(missing == 0 || isActive)

            Divider()

            Button(role: .destructive) {
                showRescanAudioAlert = true
            } label: {
                Label("Rescan everything…", systemImage: "arrow.counterclockwise")
            }
            .disabled(isActive)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "waveform")
                    .font(.system(size: 12, weight: .semibold))
                Text("Scan audio")
                    .font(.system(size: 13))
                if badgeCount > 0 {
                    Text("\(badgeCount)")
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.2))
                        .cornerRadius(4)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color.secondary.opacity(0.12)))
            .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.2), lineWidth: 0.5))
            .foregroundStyle(Color.primary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .help("Fetch BPM and key from AcousticBrainz")
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
            LazyVGrid(columns: gridColumns, spacing: 20) {
                ForEach(displayedItems) { item in
                    Button { selectedItem = item } label: {
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

    private var displayedItems: [CollectionItem] {
        var items = viewModel.items

        if activeFilter != .all {
            let matchingIds: Set<Int>
            switch activeFilter {
            case .all:
                matchingIds = []
            case .matched:
                matchingIds = Set(allEntities.filter {
                    $0.mbidScanState == "matched" || $0.mbidScanState == "matchedViaSearch" || $0.mbidScanState == "matchedManually"
                }.map(\.instanceId))
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
