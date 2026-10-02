import SwiftUI
import SwiftData
import Combine

private struct HarmonicEntry: Identifiable {
    let id: String
    let group: HarmonicGroup
    let item: CompatibleItem
}

struct SetBuilderView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.modelContext) private var modelContext
    @Environment(AudioPlaybackController.self) private var playback
    @Environment(CollectionViewModel.self) private var viewModel
    @Environment(CueDetectionCoordinator.self) private var cueCoordinator
    @Environment(SyncOrchestrator.self) private var syncOrchestrator
    @Environment(MBIDScanCoordinator.self) private var scanCoordinator
    @Environment(AudioFeaturesScanCoordinator.self) private var audioFeaturesCoordinator
    @Environment(FileMatchCoordinator.self) private var fileMatchCoordinator

    // State — Current Track is the user's focus
    @State private var currentTrack: MixTrack? = nil

    // State — pool/setlist management (filled in later steps)
    @AppStorage("setBuilderActiveSetID") private var activeSetID: String = ""
    @State private var activeSet: SetlistEntity? = nil

    // Harmonic strip controls
    @AppStorage("setBuilderBpmTolerancePct") private var bpmTolerancePct: Double = 5.0
    @AppStorage("setBuilderStopOnTrackChange") private var stopOnTrackChange: Bool = true
    @AppStorage("setBuilderAutoPlayOnPick")    private var autoPlayOnPick: Bool = true
    @State private var visibleGroups: Set<HarmonicGroup> = Set(HarmonicGroup.allCases)
    @State private var sliderDragValue: Double = 5.0
    @State private var lastBpmLiveCommit: Date = .distantPast

    // Grid state — lookups live in CollectionViewModel (computed off-main, kept across
    // sidebar switches); no @Query here, so rebuilding this view fetches nothing.
    private var coverageByInstanceId: [Int: (covered: Int, total: Int, localCovered: Int)] { viewModel.setBuilderCoverageByInstanceId }
    private var filePathToInstanceId: [String: Int] { viewModel.setBuilderFilePathToInstanceId }
    private var thumbURLs: [String: URL] { viewModel.setBuilderThumbURLs }
    private var playingInstanceId: Int? { playback.currentFilePath.flatMap { filePathToInstanceId[$0] } }
    @State private var highlightedItemId: Int? = nil
    @State private var searchQuery = ""
    @AppStorage("setBuilderFilter") private var activeFilterRaw: String = CollectionFilter.all.rawValue
    @AppStorage("setBuilderSort")   private var activeSortRaw: String   = CollectionSort.yearDesc.rawValue

    private var activeFilter: CollectionFilter { CollectionFilter(rawValue: activeFilterRaw) ?? .all }
    private var activeSort: CollectionSort     { CollectionSort(rawValue: activeSortRaw) ?? .yearDesc }
    @AppStorage("collectionGridCardSize") private var cardSize: Double = 0.25

    // Sheet state
    @State private var selectedItem: CollectionItem? = nil
    @State private var workingSetTracks: [MixTrack] = []
    @State private var showSaveSetSheet = false
    @State private var showSyncSheet = false
    @State private var newSetName = ""
    @State private var showClearConfirmation = false

    private var gridColumns: [GridItem] {
        let minWidth = 120.0 + cardSize * 160.0
        return [GridItem(.adaptive(minimum: minWidth, maximum: minWidth + 40), spacing: 16, alignment: .top)]
    }

    var body: some View {
        PerfLog.begin("SetBuilderView.body")
        defer { PerfLog.end("SetBuilderView.body") }
        return GeometryReader { windowGeo in
        ScrollViewReader { proxy in
        ScrollView {
        LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
            Section {
            VStack(spacing: 0) {

            // Current Track + Harmonic strip. With nothing picked yet there's nothing
            // live to show in either, so collapse both into one compact invitation
            // instead of reserving ~80% of window height for empty panels.
            Group {
                if let track = currentTrack {
                    VStack(spacing: 0) {
                        currentTrackHero(track: track, proxy: proxy)
                    }
                    .frame(minHeight: 200, maxHeight: max(200, windowGeo.size.height * 0.42))

                    Divider()

                    VStack(spacing: 0) {
                        harmonicStripHeader
                        harmonicStrip
                    }
                    .frame(minHeight: 160, maxHeight: max(160, windowGeo.size.height * 0.38))
                } else {
                    heroEmptyState
                        .frame(height: 220)
                }
            }
            .animation(reduceMotion ? nil : .snappy, value: currentTrack == nil)

            // Suggestions panel — only when draft is non-empty
            suggestionsPanel

            Divider()

            // Collection grid section
            gridControlsRow
            collectionGrid
            }
            } header: {
                floatingToolbar
            }
        }
        }
        .onAppear {
            viewModel.refreshSetBuilderLookups()
            if activeSet == nil, !activeSetID.isEmpty {
                let id = activeSetID
                var fd = FetchDescriptor<SetlistEntity>(predicate: #Predicate { $0.id == id })
                fd.fetchLimit = 1
                activeSet = try? modelContext.fetch(fd).first
                if activeSet == nil { activeSetID = "" }
            }
            restoreHeroIfNeeded()
            playback.smartAdvancePool = viewModel.setBuilderConfidentPool
        }
        // Replaces the old @Query count observers: any save re-checks the counts off-main.
        .onReceive(NotificationCenter.default.publisher(for: ModelContext.didSave)
            .debounce(for: .milliseconds(500), scheduler: RunLoop.main)) { _ in
            viewModel.refreshSetBuilderLookups()
        }
        .onChange(of: viewModel.setBuilderConfidentPool) { oldPool, newPool in
            // First-ever visit: the pool arrives after onAppear, so retry the hero restore once.
            if oldPool.isEmpty { restoreHeroIfNeeded() }
            playback.smartAdvancePool = newPool
        }
        .task(id: currentTrack?.filePath) {
            if let fp = currentTrack?.filePath {
                playback.loadWaveformIfNeeded(filePath: fp)
            }
        }
        .sheet(item: $selectedItem) { item in
            CollectionDetailView(item: item, onPromoteToCurrent: { track in
                handleTrackPick(track)
            })
        }
        .sheet(isPresented: $showSyncSheet) {
            SyncProgressView()
                .environment(syncOrchestrator)
        }
        .sheet(isPresented: $showSaveSetSheet) {
            VStack(spacing: 16) {
                Text("Save Set").font(.headline)
                Text("\(workingSetTracks.count) tracks").font(.subheadline).foregroundStyle(.secondary)
                TextField("Set name", text: $newSetName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 280)
                HStack(spacing: 12) {
                    Button("Cancel") {
                        showSaveSetSheet = false
                        newSetName = ""
                    }
                    Button("Save") { saveWorkingSet() }
                        .buttonStyle(.borderedProminent)
                        .disabled(newSetName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(28)
            .frame(width: 360, height: 200)
        }
        .onChange(of: highlightedItemId) { _, newVal in
            guard newVal != nil else { return }
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                await MainActor.run { highlightedItemId = nil }
            }
        }
        .overlay(alignment: .top) {
            if scanCoordinator.shouldShowPanel {
                MBIDScanResultsView(
                    coordinator: scanCoordinator,
                    onFilterSelect: { filter in activeFilterRaw = filter.rawValue },
                    onOpenItem: { instanceId in
                        selectedItem = viewModel.items.first { $0.id == instanceId }
                    }
                )
                .padding(.top, 12)
            }
        }
        } // ScrollViewReader
        } // GeometryReader
    }

    /// Restore hero if we navigated away while a track was loaded.
    /// loadedFilePath covers load-without-play; currentFilePath covers played-then-paused.
    private func restoreHeroIfNeeded() {
        guard currentTrack == nil else { return }
        let fp = playback.loadedFilePath ?? playback.currentFilePath
        if let fp { currentTrack = viewModel.setBuilderConfidentPool.first(where: { $0.filePath == fp }) }
    }

    // MARK: - Track pick handler

    private func handleTrackPick(_ track: MixTrack) {
        if stopOnTrackChange { playback.pause() }
        currentTrack = track
        if workingSetTracks.last?.id != track.id {
            workingSetTracks.append(track)
        }
        if autoPlayOnPick, let fp = track.filePath {
            playback.play(filePath: fp)
        } else {
            playback.setLoadedFile(track.filePath)
        }
    }

    private func saveWorkingSet() {
        let name = newSetName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let newSet = SetlistEntity(name: name)
        modelContext.insert(newSet)
        for (index, track) in workingSetTracks.enumerated() {
            let item = SetlistItemEntity(
                position: index,
                filePath: track.filePath ?? "",
                displayArtist: track.displayArtist,
                displayTitle: track.displayTitle,
                bpm: track.bpm,
                camelot: track.camelot,
                key: track.key
            )
            newSet.items.append(item)
            modelContext.insert(item)
        }
        do {
            try modelContext.save()
            workingSetTracks = []
            currentTrack = nil
            playback.setLoadedFile(nil)
            showSaveSetSheet = false
            newSetName = ""
        } catch {
            print("[SetBuilder] Failed to save set: \(error)")
        }
    }

    // MARK: - Floating toolbar

    private var floatingToolbar: some View {
        HStack {
            Text("Set Builder").font(.headline)
            if !workingSetTracks.isEmpty {
                Text("· \(workingSetTracks.count) track\(workingSetTracks.count == 1 ? "" : "s")")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !workingSetTracks.isEmpty {
                Button("Save Set") { showSaveSetSheet = true }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                Button("Clear") {
                    if workingSetTracks.count >= 2 {
                        showClearConfirmation = true
                    } else {
                        workingSetTracks = []
                        currentTrack = nil
                        playback.setLoadedFile(nil)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .confirmationDialog(
                    "Clear \(workingSetTracks.count) tracks from this set?",
                    isPresented: $showClearConfirmation,
                    titleVisibility: .visible
                ) {
                    Button("Clear \(workingSetTracks.count) Tracks", role: .destructive) {
                        workingSetTracks = []
                        currentTrack = nil
                        playback.setLoadedFile(nil)
                    }
                    Button("Cancel", role: .cancel) { }
                }
            }
            Menu {
                Toggle("Auto-play on pick", isOn: $autoPlayOnPick)
                Toggle("Stop playback when changing track", isOn: $stopOnTrackChange)
            } label: {
                Image(systemName: "gearshape")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 28)
            .help("Set Builder settings")
            .accessibilityLabel("Set Builder settings")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) {
            LinearGradient(
                colors: [Color.primary.opacity(0.08), Color.primary.opacity(0)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 8)
        }
    }

    // MARK: - Harmonic strip

    private var pool: [MixTrack] {
        viewModel.setBuilderConfidentPool
    }

    private var compatibleItems: [HarmonicEntry] {
        guard let anchor = currentTrack else { return [] }
        let absoluteTolerance = anchor.bpm * bpmTolerancePct / 100.0
        let grouped = HarmonicCompatibility.compatibleGroups(
            for: anchor, in: pool, bpmTolerance: absoluteTolerance)
        var result: [HarmonicEntry] = []
        for group in HarmonicGroup.allCases where visibleGroups.contains(group) {
            if let items = grouped[group] {
                result.append(contentsOf: items.map { HarmonicEntry(id: $0.id, group: group, item: $0) })
            }
        }
        return result
    }

    private var harmonicStripHeader: some View {
        HStack(spacing: 12) {
            Text("Compatible tracks")
                .font(.headline)

            ForEach(HarmonicGroup.allCases, id: \.self) { group in
                Button {
                    Task { @MainActor in
                        await Task.yield()
                        if visibleGroups.contains(group) {
                            visibleGroups.remove(group)
                        } else {
                            visibleGroups.insert(group)
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(visibleGroups.contains(group) ? group.color : Color.clear)
                            .overlay(Circle().stroke(group.color, lineWidth: 1.5))
                            .frame(width: 10, height: 10)
                        Text(group.shortName).font(.caption)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Capsule().fill(visibleGroups.contains(group) ? group.color.opacity(0.12) : Color.clear))
                    .overlay(Capsule().stroke(Color.secondary.opacity(0.3), lineWidth: 0.5))
                }
                .buttonStyle(.plain)
            }

            Spacer()

            HStack(spacing: 4) {
                Text("\(String(format: "%.1f", sliderDragValue))% BPM")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Slider(
                    value: $sliderDragValue,
                    in: 1...20,
                    step: 0.5,
                    onEditingChanged: { editing in
                        if !editing { bpmTolerancePct = sliderDragValue }
                    }
                )
                .frame(width: 120)
                .controlSize(.mini)
                .onAppear { sliderDragValue = bpmTolerancePct }
                .onChange(of: sliderDragValue) { _, newValue in
                    let now = Date.now
                    guard now.timeIntervalSince(lastBpmLiveCommit) >= 0.1 else { return }
                    lastBpmLiveCommit = now
                    bpmTolerancePct = newValue
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 0.5)
        }
    }

    @ViewBuilder
    private var harmonicStrip: some View {
        // ponytail: currentTrack is always non-nil here — this view only renders inside
        // the `if let track` branch of the hero/strip Group in body.
        if compatibleItems.isEmpty {
            emptyStripState
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(compatibleItems) { entry in
                        Button {
                            handleTrackPick(entry.item.track)
                        } label: {
                            StripTileView(
                                track: entry.item.track,
                                group: entry.group,
                                thumbURL: thumbURLs[entry.item.track.filePath ?? ""],
                                releaseName: nil,
                                isCandidate: false
                            )
                        }
                        .buttonStyle(InteractiveTileButtonStyle())
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 4)
            }
        }
    }

    private var emptyStripState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "exclamationmark.magnifyingglass")
                .font(.iconLarge)
                .foregroundStyle(.secondary)
            VStack(spacing: 4) {
                Text("No compatible tracks nearby")
                    .font(.title3.weight(.semibold))
                    .tracking(-0.2)
                Text("Nothing matches within ±\(String(format: "%.1f", bpmTolerancePct))% BPM tolerance.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Button("Widen to 10%") { bpmTolerancePct = 10.0 }
                    .controlSize(.small)
                Button("Widen to 20%") { bpmTolerancePct = 20.0 }
                    .controlSize(.small)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Suggestions panel

    @ViewBuilder
    private var suggestionsPanel: some View {
        if !workingSetTracks.isEmpty, let anchor = workingSetTracks.last {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Image(systemName: "wand.and.stars")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.tint)
                    Text("Next in Set")
                        .font(.body.weight(.semibold))
                    Text("\(workingSetTracks.count) so far · anchored to '\(anchor.displayTitle)'")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                }
                .padding(.horizontal, 20)

                suggestionsContent(anchor: anchor)
            }
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.secondary.opacity(0.04))
                    .padding(.horizontal, 12)
            )
            .padding(.bottom, 8)
        }
    }

    @ViewBuilder
    private func suggestionsContent(anchor: MixTrack) -> some View {
        if anchor.camelot.isEmpty || anchor.bpm <= 0 {
            Text("Last track has no harmonic data — no suggestions available.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
        } else {
            let candidates = rankedSuggestions(for: anchor, limit: 10)
            if candidates.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("No compatible tracks at ±\(Int(bpmTolerancePct))% BPM tolerance.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Button("Widen to ±10%") { bpmTolerancePct = 10 }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        Button("Widen to ±20%") { bpmTolerancePct = 20 }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(candidates, id: \.track.filePath) { item in
                            Button {
                                handleTrackPick(item.track)
                            } label: {
                                TransitionBubbleView(anchor: anchor, candidate: item.track)
                            }
                            .buttonStyle(InteractiveTileButtonStyle())
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private func rankedSuggestions(for anchor: MixTrack, limit: Int) -> [CompatibleItem] {
        let absoluteTolerance = anchor.bpm * (bpmTolerancePct / 100.0)
        let groups = HarmonicCompatibility.compatibleGroups(
            for: anchor, in: pool, bpmTolerance: absoluteTolerance)
        let excludedPaths = Set(workingSetTracks.compactMap { $0.filePath })
        let groupOrder: [HarmonicGroup] = [.perfectMatch, .moodSwitch, .energyBoost, .energyDrop]
        var ranked: [CompatibleItem] = []
        for group in groupOrder {
            guard let items = groups[group] else { continue }
            for item in items {
                guard let path = item.track.filePath, !excludedPaths.contains(path) else { continue }
                ranked.append(item)
                if ranked.count >= limit { return ranked }
            }
        }
        return ranked
    }

    // MARK: - Current Track hero

    private var heroEmptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "rectangle.stack.badge.plus")
                .font(.iconLarge)
                .foregroundStyle(.secondary)
            VStack(spacing: 4) {
                Text("Choose a track below to start building a set.")
                    .font(.title3.weight(.semibold))
                    .tracking(-0.2)
                Text("Its harmonic matches will show up here.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func currentTrackHero(track: MixTrack, proxy: ScrollViewProxy) -> some View {
        VStack(spacing: 0) {
            // Top row: cover + info (~180pt)
            HStack(alignment: .top, spacing: 16) {
                Button {
                    guard let instanceId = filePathToInstanceId[track.filePath ?? ""] else { return }
                    activeFilterRaw = CollectionFilter.all.rawValue
                    highlightedItemId = instanceId
                    withAnimation(reduceMotion ? nil : .smooth) {
                        proxy.scrollTo(instanceId, anchor: .center)
                    }
                } label: {
                    AsyncImage(url: thumbURLs[track.filePath ?? ""]) { phase in
                        switch phase {
                        case .success(let img):
                            img.resizable().aspectRatio(contentMode: .fill)
                        default:
                            ZStack {
                                Color.secondary.opacity(0.10)
                                Image(systemName: "music.note")
                                    .font(.iconLarge)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .frame(width: 180, height: 180)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .shadow(color: .black.opacity(0.20), radius: 8, x: 0, y: 4)
                }
                .buttonStyle(.plain)
                .help("Show in Collection")
                .accessibilityLabel("Show in Collection")

                VStack(alignment: .leading, spacing: 6) {
                    Text(track.displayTitle)
                        .font(.title2.bold())
                        .tracking(-0.4)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 6) {
                        Text(track.displayArtist)
                            .font(.title3)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Button {
                            // Pop from draft only when the hero is the last-added entry
                            // (guards against clearing the draft while just browsing)
                            if let hero = currentTrack,
                               workingSetTracks.last == hero {
                                workingSetTracks.removeLast()
                            }
                            currentTrack = workingSetTracks.last
                            playback.setLoadedFile(workingSetTracks.last?.filePath)
                        } label: {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.white)
                                .frame(width: 22, height: 22)
                                .background(Circle().fill(Color.accentColor))
                                .hitTarget()
                        }
                        .buttonStyle(.plain)
                        .help("Change current track")
                        .accessibilityLabel("Change current track")
                    }

                    let labelYear: String = {
                        switch (track.label.isEmpty, track.year == 0) {
                        case (false, false): return "\(track.label) · \(track.year)"
                        case (false, true):  return track.label
                        case (true, false):  return "\(track.year)"
                        case (true, true):   return ""
                        }
                    }()
                    if !labelYear.isEmpty {
                        Text(labelYear)
                            .font(.subheadline)
                            .foregroundStyle(Color.secondary.opacity(0.85))
                            .lineLimit(1)
                    }

                    Spacer()

                    HStack(spacing: 6) {
                        if track.bpm > 0 {
                            heroBadge("\(Int(track.bpm.rounded())) BPM", monospaced: true)
                        }
                        if !track.camelot.isEmpty {
                            heroCamelotPill(track.camelot)
                        }
                        if !track.key.isEmpty {
                            heroBadge(track.key, monospaced: false)
                        }
                        heroSourcePill(track.source)
                    }
                }
                .padding(.leading, 4)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(height: 180)
            .padding(.horizontal, 16)
            .padding(.top, 12)

            // Bottom row: play button + waveform (~88pt)
            if let fp = track.filePath, !fp.isEmpty {
                let isActive  = playback.currentFilePath == fp
                let isPlaying = isActive && playback.isPlaying
                HStack(spacing: 10) {
                    Button {
                        playback.play(filePath: fp)
                    } label: {
                        Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.title)
                            .foregroundStyle(isActive ? Color.accentColor : Color.secondary.opacity(0.5))
                            .contentTransition(reduceMotion ? .opacity : .symbolEffect(.replace))
                    }
                    .buttonStyle(.plain)

                    TrackWaveformView(filePath: fp, zoomFactor: .constant(1.0))
                        .id(fp)

                    Button {
                        cueCoordinator.startDetection(filePath: fp)
                    } label: {
                        if cueCoordinator.phase == .detecting
                            && cueCoordinator.currentFileLabel
                                == URL(fileURLWithPath: fp).lastPathComponent {
                            ProgressView()
                                .scaleEffect(0.55)
                                .frame(width: 22, height: 22)
                        } else if cueCoordinator.failureMessage != nil {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.title2)
                                .foregroundStyle(.red)
                                .frame(width: 22, height: 22)
                        } else {
                            Image(systemName: "waveform.path.ecg")
                                .font(.title2)
                                .foregroundStyle(Color.secondary.opacity(0.8))
                                .frame(width: 22, height: 22)
                        }
                    }
                    .buttonStyle(.plain)
                    .help(cueCoordinator.failureMessage ?? "Scan cue points for this track")
                    .accessibilityLabel("Scan cue points for this track")
                    .disabled(cueCoordinator.phase == .detecting)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 10)
            } else {
                Color.clear.frame(height: 88)
            }
        }
    }

    // MARK: - Hero badge helpers

    @ViewBuilder
    private func heroBadge(_ text: String, monospaced: Bool) -> some View {
        Text(text)
            .font(monospaced
                  ? .callout.weight(.semibold).monospacedDigit()
                  : .callout)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(Color.secondary.opacity(0.12)))
    }

    @ViewBuilder
    private func heroCamelotPill(_ code: String) -> some View {
        Text(code)
            .font(.callout.weight(.bold).monospacedDigit())
            .foregroundStyle(CamelotColor.text(for: code))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(CamelotColor.background(for: code)))
    }

    @ViewBuilder
    private func heroSourcePill(_ source: TrackEntity.FeatureSource) -> some View {
        switch source {
        case .local:
            Text("ES")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(Capsule().fill(Color.statusComplete))
                .help("BPM & key analyzed from your local audio file (Essentia)")
                .accessibilityLabel("BPM & key analyzed from your local audio file (Essentia)")
        case .ab:
            Text("AB")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(Capsule().fill(Color.badgeSecondarySource))
                .help("BPM & key from AcousticBrainz")
                .accessibilityLabel("BPM & key from AcousticBrainz")
        case .none:
            EmptyView()
        }
    }

    // MARK: - Grid controls row

    private var gridControlsRow: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.body)
                    .foregroundStyle(.secondary)
                TextField("Search artist, title, year…", text: $searchQuery)
                    .textFieldStyle(.plain)
                    .font(.body)
                if !searchQuery.isEmpty {
                    Button { searchQuery = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.body)
                            .foregroundStyle(Color.secondary.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                    .help("Clear search")
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: 280)
            .background(Capsule().fill(Color.secondary.opacity(0.10)))
            .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.2), lineWidth: 0.5))

            HStack(spacing: 4) {
                Image(systemName: "square.grid.3x3")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Slider(value: $cardSize, in: 0...1)
                    .frame(width: 64)
                    .controlSize(.mini)
                Image(systemName: "square.grid.2x2")
                    .font(.body)
                    .foregroundStyle(.tertiary)
            }

            sortButton
            filterButton
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Color.secondary.opacity(0.05))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 0.5)
        }
    }

    // MARK: - Collection grid

    @ViewBuilder
    private var collectionGrid: some View {
        let allItems     = displayedItems
        let albums       = allItems.filter { !$0.isCompilation }
        let compilations = allItems.filter {  $0.isCompilation }

        if viewModel.items.isEmpty {
            emptyState
        } else if albums.isEmpty && compilations.isEmpty && activeFilter != .all {
            filteredEmptyState
        } else {
            VStack(spacing: 24) {
                if !albums.isEmpty {
                    sectionHeader(title: "12\" Maxi-Singles", count: albums.count)
                    LazyVGrid(columns: gridColumns, spacing: 20) {
                        ForEach(albums) { item in
                            cardButton(for: item)
                        }
                    }
                }

                if !compilations.isEmpty {
                    sectionHeader(title: "Compilations", count: compilations.count)
                    LazyVGrid(columns: gridColumns, spacing: 20) {
                        ForEach(compilations) { item in
                            cardButton(for: item)
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, minHeight: 600, alignment: .top)
        }
    }

    @ViewBuilder
    private func cardButton(for item: CollectionItem) -> some View {
        Button { selectedItem = item } label: {
            CollectionCardView(
                item: item,
                hasMBID: matchedInstanceIds.contains(item.id),
                covered: coverageByInstanceId[item.id]?.covered ?? 0,
                total: coverageByInstanceId[item.id]?.total ?? 0,
                localCovered: coverageByInstanceId[item.id]?.localCovered ?? 0,
                isActive: playingInstanceId == item.id,
                isHighlighted: item.id == highlightedItemId
            )
        }
        .buttonStyle(InteractiveTileButtonStyle())
        .id(item.id)
    }

    @ViewBuilder
    private func sectionHeader(title: String, count: Int) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)

            Text("\(count)")
                .font(.body.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.15))
                .clipShape(Capsule())

            Spacer()
        }
        .padding(.bottom, 4)
    }

    // MARK: - Sort button

    private var sortButton: some View {
        Menu {
            ForEach(CollectionSort.allCases) { sort in
                Button { activeSortRaw = sort.rawValue } label: {
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
                Image(systemName: activeSort.icon).font(.callout.weight(.semibold))
                Text(activeSort.rawValue).font(.body)
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
                Button { activeFilterRaw = filter.rawValue } label: {
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
                Image(systemName: activeFilter.icon).font(.callout.weight(.semibold))
                Text("\(activeFilter.rawValue) (\(filterCount(for: activeFilter)))").font(.body)
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
                .font(.iconHero).foregroundStyle(.secondary)
            Text("No releases match the current filter.").foregroundStyle(.secondary)
            Button("Clear filter") { activeFilterRaw = CollectionFilter.all.rawValue }.buttonStyle(.bordered)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "record.circle").font(.iconHero).foregroundStyle(.secondary)
            Text("Your collection will appear here.").foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Computed helpers

    private var matchedInstanceIds: Set<Int> {
        Set(viewModel.setBuilderScanStates.filter {
            $0.value == "matched" ||
            $0.value == "matchedViaSearch" ||
            $0.value == "matchedManually"
        }.map(\.key))
    }

    private func filterCount(for filter: CollectionFilter) -> Int {
        switch filter {
        case .all:       return viewModel.items.count
        case .matched:   return viewModel.setBuilderScanStates.values.filter {
            $0 == "matched" ||
            $0 == "matchedViaSearch" ||
            $0 == "matchedManually"
        }.count
        case .needsReview: return viewModel.setBuilderScanStates.values.filter { $0 == "needsReview" }.count
        case .notFound:  return viewModel.setBuilderScanStates.values.filter { $0 == "notFound" }.count
        case .failed:    return viewModel.setBuilderScanStates.values.filter { $0 == "failed" }.count
        case .unscanned: return viewModel.setBuilderScanStates.values.filter { $0 == "unscanned" }.count
        }
    }

    private var displayedItems: [CollectionItem] {
        var items = viewModel.items

        if activeFilter != .all {
            let matchingIds: Set<Int>
            switch activeFilter {
            case .all:       matchingIds = []
            case .matched:
                matchingIds = Set(viewModel.setBuilderScanStates.filter {
                    $0.value == "matched" ||
                    $0.value == "matchedViaSearch" ||
                    $0.value == "matchedManually"
                }.map(\.key))
            case .needsReview:
                matchingIds = Set(viewModel.setBuilderScanStates.filter { $0.value == "needsReview" }.map(\.key))
            case .notFound:
                matchingIds = Set(viewModel.setBuilderScanStates.filter { $0.value == "notFound" }.map(\.key))
            case .failed:
                matchingIds = Set(viewModel.setBuilderScanStates.filter { $0.value == "failed" }.map(\.key))
            case .unscanned:
                matchingIds = Set(viewModel.setBuilderScanStates.filter { $0.value == "unscanned" }.map(\.key))
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

private extension CollectionItem {
    var isCompilation: Bool {
        basicInformation.artists.first?.name.lowercased() == "various"
    }
}
