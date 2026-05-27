import SwiftUI
import SwiftData
import AppKit

enum MixScope: String, CaseIterable {
    case confident   = "Discogs collection"
    case allAnalyzed = "All analyzed"
}

// MARK: - Main view

struct MixModeView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(CollectionViewModel.self) private var viewModel
    @Environment(AudioPlaybackController.self) private var playback

    @Query(sort: \SetlistEntity.createdAt, order: .reverse)
    private var allSets: [SetlistEntity]
    @Query private var allTrackEntities: [TrackEntity]
    @Query(filter: #Predicate<LocalFileEntity> { $0.bpm > 0 })
    private var analyzedFiles: [LocalFileEntity]
    @Query private var allCollectionEntities: [CollectionItemEntity]

    // Set & scope
    @AppStorage("mixActiveSetID") private var activeSetID: String = ""
    @State private var activeSet: SetlistEntity?
    @State private var scope: MixScope = .confident

    // Pool + lookups (rebuilt when scope/data changes)
    @State private var pool: [MixTrack] = []
    @State private var thumbURLs: [String: URL] = [:]
    @State private var releaseNameByPath: [String: String] = [:]
    @State private var mixableCount: [Int: Int] = [:]

    // Building state
    @State private var candidateTrack: MixTrack? = nil
    @AppStorage("mixBpmTolerance") private var bpmTolerance: Double = 6.0

    // Strip group-filter chips
    @State private var showPerfect: Bool = true
    @State private var showBoost:   Bool = true
    @State private var showDrop:    Bool = true
    @State private var showMood:    Bool = true

    // Track picker sheet
    @State private var trackPickerRelease: CollectionItemEntity? = nil

    // Search
    @State private var searchText: String = ""

    // Shared grid sizing
    @AppStorage("collectionGridCardSize") private var cardSize: Double = 0.25
    private var gridColumns: [GridItem] {
        let minWidth = 120.0 + cardSize * 160.0
        return [GridItem(.adaptive(minimum: minWidth, maximum: minWidth + 40), spacing: 16)]
    }

    // MARK: - Computed

    private var anchorTrack: MixTrack? {
        guard let set = activeSet else { return nil }
        guard let last = set.items.sorted(by: { $0.position < $1.position }).last else { return nil }
        return MixTrack(
            displayArtist: last.displayArtist,
            displayTitle:  last.displayTitle,
            bpm:           last.bpm,
            camelot:       last.camelot,
            key:           last.key,
            source:        .local,
            filePath:      last.filePath.isEmpty ? nil : last.filePath
        )
    }

    private var absoluteBpmTolerance: Double {
        guard let anchor = anchorTrack, anchor.bpm > 0 else { return 0 }
        return anchor.bpm * bpmTolerance / 100.0
    }

    private var visibleGroups: [HarmonicGroup] {
        var g: [HarmonicGroup] = []
        if showPerfect { g.append(.perfectMatch) }
        if showBoost   { g.append(.energyBoost) }
        if showDrop    { g.append(.energyDrop) }
        if showMood    { g.append(.moodSwitch) }
        return g
    }

    private func compatibleItems(for anchor: MixTrack) -> [(track: MixTrack, group: HarmonicGroup)] {
        let grouped = HarmonicCompatibility.compatibleGroups(
            for: anchor, in: pool, bpmTolerance: absoluteBpmTolerance)
        return visibleGroups.flatMap { group in
            (grouped[group] ?? []).map { ($0.track, group) }
        }
    }

    private var filteredItems: [CollectionItem] {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return viewModel.items }
        let lower = q.lowercased()
        return viewModel.items.filter { item in
            item.basicInformation.title.lowercased().contains(lower)
            || item.basicInformation.artists.contains { $0.name.lowercased().contains(lower) }
        }
    }

    private var bpmRangeLabel: String {
        guard let a = anchorTrack, a.bpm > 0, bpmTolerance > 0 else { return "" }
        let pct = bpmTolerance / 100.0
        return "\(Int((a.bpm * (1 - pct)).rounded()))–\(Int((a.bpm * (1 + pct)).rounded()))"
    }

    // MARK: - Body

    var body: some View {
        let anchor     = anchorTrack
        let compatible = anchor.map { compatibleItems(for: $0) } ?? []

        VStack(spacing: 0) {
            topBar
            Divider()

            if let a = anchor {
                statsBar(matchCount: compatible.count, anchor: a)
                Divider()
                deckRow(anchor: a)
                Divider()
                bpmSliderRow(anchor: a)
                Divider()
                compatibleHeader(matchCount: compatible.count, anchor: a)
                harmonicStrip(items: compatible)
                stripFilterChips
                Divider()
            } else if activeSet != nil {
                emptySetPrompt
                Divider()
            }

            searchRow
            coverGrid
        }
        .onAppear {
            rebuildPool()
            if activeSet == nil, !activeSetID.isEmpty {
                activeSet = allSets.first { $0.id == activeSetID }
                if activeSet == nil { activeSetID = "" }  // stored set was deleted
            }
        }
        .onChange(of: scope)                    { _, _ in rebuildPool() }
        .onChange(of: allTrackEntities.count)    { _, _ in rebuildPool() }
        .onChange(of: analyzedFiles.count)      { _, _ in rebuildPool() }
        .onChange(of: allCollectionEntities.count) { _, _ in rebuildMixableCount() }
        .onChange(of: activeSet) { _, newSet in
            activeSetID = newSet?.id ?? ""
        }
        .onChange(of: allSets) { _, newSets in
            if let active = activeSet, !newSets.contains(active) {
                activeSet = nil
                activeSetID = ""
            }
        }
        .onChange(of: candidateTrack) { _, val in
            if let fp = val?.filePath {
                playback.loadWaveformIfNeeded(filePath: fp)
                playback.preloadAudio(filePath: fp)
            } else {
                playback.cancelPreload()
            }
        }
        .sheet(item: $trackPickerRelease) { entity in
            TrackPickerSheet(entity: entity) { track in handleTrackPick(track) }
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(spacing: 12) {
            setPickerMenu
            Spacer()
            Picker("Scope", selection: $scope) {
                ForEach(MixScope.allCases, id: \.self) { s in Text(s.rawValue).tag(s) }
            }
            .pickerStyle(.segmented)
            .frame(width: 280)
            .labelsHidden()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.secondary.opacity(0.04))
    }

    private var setPickerMenu: some View {
        Menu {
            ForEach(allSets) { set in
                Button { activeSet = set } label: {
                    HStack {
                        Text(set.name)
                        if activeSet == set { Image(systemName: "checkmark") }
                    }
                }
            }
            if !allSets.isEmpty { Divider() }
            Button { createAndSelectNewSet() } label: {
                Label("New set…", systemImage: "plus")
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "list.bullet.rectangle").font(.system(size: 12, weight: .semibold))
                Text(activeSet?.name ?? "Select a set…").font(.system(size: 13))
                Image(systemName: "chevron.down").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Capsule().fill(activeSet != nil ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.12)))
            .overlay(Capsule().strokeBorder(activeSet != nil ? Color.accentColor.opacity(0.3) : Color.secondary.opacity(0.2), lineWidth: 0.5))
            .foregroundStyle(activeSet != nil ? Color.accentColor : Color.primary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
    }

    // MARK: - Stats bar

    private func statsBar(matchCount: Int, anchor: MixTrack) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 12))
                .foregroundStyle(Color.accentColor)
            Text("Harmonic Mixing")
                .font(.system(size: 12, weight: .semibold))
            dot
            Text("\(matchCount) match\(matchCount == 1 ? "" : "es")")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            dot
            Text("\(Int(anchor.bpm.rounded())) BPM")
                .font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
            dot
            camelotPill(anchor.camelot, fontSize: 9)
            dot
            Text("±\(Int(bpmTolerance.rounded()))%")
                .font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 14).padding(.vertical, 7)
        .background(Color.secondary.opacity(0.03))
    }

    private var dot: some View {
        Text("·").foregroundStyle(.tertiary)
    }

    // MARK: - Deck row

    @ViewBuilder
    private func deckRow(anchor: MixTrack) -> some View {
        VStack(spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                DeckCardView(
                    label: "NOW PLAYING",
                    track: anchor,
                    coverURL: thumbURLs[anchor.filePath ?? ""],
                    tintColor: .accentColor,
                    onDismiss: {}
                )
                if let candidate = candidateTrack {
                    TransitionBubbleView(anchor: anchor, candidate: candidate)
                } else {
                    Color.clear.frame(width: 96)
                }
                DeckCardView(
                    label: "NEXT UP",
                    track: candidateTrack,
                    coverURL: candidateTrack.flatMap { thumbURLs[$0.filePath ?? ""] },
                    tintColor: .orange,
                    dismissable: true,
                    onDismiss: { candidateTrack = nil }
                )
            }
            if candidateTrack != nil {
                HStack {
                    Spacer()
                    Button("Add to Set") { addCandidateToSet() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
                .padding(.horizontal, 2)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, candidateTrack != nil ? 8 : 10)
        .background(Color.secondary.opacity(0.03))
    }

    // MARK: - BPM slider

    private func bpmSliderRow(anchor: MixTrack) -> some View {
        HStack(spacing: 10) {
            Text("BPM").font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 32, alignment: .leading)
            Slider(value: $bpmTolerance, in: 0...15, step: 0.5)
            Text("±\(Int(bpmTolerance.rounded()))%")
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .frame(width: 36, alignment: .trailing)
            Text(bpmRangeLabel)
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 60, alignment: .trailing)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    // MARK: - Compatible-with header

    private func compatibleHeader(matchCount: Int, anchor: MixTrack) -> some View {
        HStack(spacing: 8) {
            Text("Compatible with").font(.system(size: 12)).foregroundStyle(.secondary)
            Text(anchor.displayTitle)
                .font(.system(size: 12, weight: .semibold)).lineLimit(1)
            Spacer()
            ForEach([HarmonicGroup.perfectMatch, .energyBoost, .moodSwitch], id: \.self) { g in
                HStack(spacing: 3) {
                    Circle().fill(g.color).frame(width: 7, height: 7)
                    Text(g.shortName).font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            Text("(\(matchCount))")
                .font(.system(size: 11).monospacedDigit()).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14).padding(.vertical, 7)
    }

    // MARK: - Harmonic strip

    @ViewBuilder
    private func harmonicStrip(items: [(track: MixTrack, group: HarmonicGroup)]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                if items.isEmpty {
                    Text("No compatible tracks within ±\(Int(bpmTolerance.rounded()))%")
                        .font(.callout).foregroundStyle(.tertiary)
                        .frame(height: 240).frame(minWidth: 300)
                } else {
                    ForEach(items, id: \.track.id) { item in
                        StripTileView(
                            track: item.track,
                            group: item.group,
                            thumbURL: thumbURLs[item.track.filePath ?? ""],
                            releaseName: releaseNameByPath[item.track.filePath ?? ""],
                            isCandidate: candidateTrack?.id == item.track.id
                        )
                        .onTapGesture { candidateTrack = item.track }
                    }
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
        }
        .frame(height: 272)
        .background(Color.secondary.opacity(0.02))
    }

    // MARK: - Strip filter chips

    private var stripFilterChips: some View {
        HStack(spacing: 8) {
            filterChip("Perfect match", icon: HarmonicGroup.perfectMatch.systemImage,
                       color: HarmonicGroup.perfectMatch.color, isOn: $showPerfect)
            filterChip("Energy boost",  icon: HarmonicGroup.energyBoost.systemImage,
                       color: HarmonicGroup.energyBoost.color,  isOn: $showBoost)
            filterChip("Energy drop",   icon: HarmonicGroup.energyDrop.systemImage,
                       color: HarmonicGroup.energyDrop.color,   isOn: $showDrop)
            filterChip("Mood switch",   icon: HarmonicGroup.moodSwitch.systemImage,
                       color: HarmonicGroup.moodSwitch.color,   isOn: $showMood)
            Spacer()
        }
        .padding(.horizontal, 14).padding(.vertical, 7)
    }

    @ViewBuilder
    private func filterChip(_ label: String, icon: String, color: Color, isOn: Binding<Bool>) -> some View {
        Button { isOn.wrappedValue.toggle() } label: {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 10))
                    .foregroundStyle(isOn.wrappedValue ? color : Color.secondary)
                Text(label).font(.system(size: 11, weight: .medium))
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Capsule().fill(isOn.wrappedValue ? color.opacity(0.12) : Color.secondary.opacity(0.08)))
            .overlay(Capsule().strokeBorder(isOn.wrappedValue ? color.opacity(0.35) : Color.secondary.opacity(0.15), lineWidth: 0.5))
            .foregroundStyle(isOn.wrappedValue ? color : Color.secondary)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Empty-set prompt

    private var emptySetPrompt: some View {
        HStack(spacing: 8) {
            Image(systemName: "hand.tap").font(.system(size: 13)).foregroundStyle(.secondary)
            Text("Tap a release below to pick the opening track for \"\(activeSet?.name ?? "this set")\"")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Search row

    private var searchRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            TextField("Search releases…", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.secondary.opacity(0.6))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: - Cover grid

    private var coverGrid: some View {
        ScrollView {
            LazyVGrid(columns: gridColumns, spacing: 20) {
                ForEach(filteredItems) { item in
                    let count = mixableCount[item.id] ?? 0
                    Button {
                        guard activeSet != nil, count > 0 else { return }
                        if let entity = allCollectionEntities.first(where: { $0.instanceId == item.id }) {
                            trackPickerRelease = entity
                        }
                    } label: {
                        ZStack(alignment: .bottomLeading) {
                            CollectionCardView(
                                item: item, hasMBID: false,
                                covered: 0, total: 0, localCovered: 0, isActive: false
                            )
                            .opacity(count == 0 ? 0.38 : 1.0)
                            if count > 0 {
                                mixableBadge(count)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .opacity(activeSet == nil ? 0.45 : 1.0)
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            if activeSet == nil {
                VStack(spacing: 10) {
                    Image(systemName: "list.bullet.rectangle")
                        .font(.system(size: 36)).foregroundStyle(.tertiary)
                    Text("Select or create a set above to start mixing")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func mixableBadge(_ count: Int) -> some View {
        HStack(spacing: 3) {
            Image(systemName: "waveform")
                .font(.system(size: 8, weight: .semibold))
            Text("\(count)")
                .font(.system(size: 9, weight: .bold).monospacedDigit())
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color(red: 0.15, green: 0.55, blue: 0.30)))
        .padding(.leading, 6)
        .padding(.bottom, 6)
    }

    // MARK: - Pool rebuild

    private func rebuildPool() {
        switch scope {
        case .confident:   pool = MixTrackPool.confident(from: allTrackEntities)
        case .allAnalyzed: pool = MixTrackPool.allAnalyzed(from: analyzedFiles)
        }
        thumbURLs = MixCoverArt.thumbURLs(from: allTrackEntities)
        var names: [String: String] = [:]
        names.reserveCapacity(allTrackEntities.count)
        for t in allTrackEntities {
            guard let fp = t.primaryLocalFilePath, !fp.isEmpty,
                  let title = t.collectionItem?.basicInformation?.title, !title.isEmpty else { continue }
            names[fp] = title
        }
        releaseNameByPath = names
        rebuildMixableCount()
    }

    private func rebuildMixableCount() {
        var counts: [Int: Int] = [:]
        counts.reserveCapacity(allCollectionEntities.count)
        for entity in allCollectionEntities {
            counts[entity.instanceId] = entity.tracks.filter {
                $0.effectiveBpm != nil && !($0.effectiveCamelot ?? "").isEmpty
            }.count
        }
        mixableCount = counts
    }

    // MARK: - Actions

    private func handleTrackPick(_ track: MixTrack) {
        guard let set = activeSet else { return }
        let sorted = set.items.sorted { $0.position < $1.position }
        if sorted.isEmpty {
            let item = SetlistItemEntity(
                position: 0,
                filePath: track.filePath ?? "",
                displayArtist: track.displayArtist,
                displayTitle: track.displayTitle,
                bpm: track.bpm, camelot: track.camelot, key: track.key
            )
            item.setlist = set
            modelContext.insert(item)
            try? modelContext.save()
        } else {
            candidateTrack = track
        }
    }

    private func addCandidateToSet() {
        guard let track = candidateTrack, let set = activeSet else { return }
        let sorted = set.items.sorted { $0.position < $1.position }
        let nextPos = (sorted.map(\.position).max() ?? -1) + 1
        let item = SetlistItemEntity(
            position: nextPos,
            filePath: track.filePath ?? "",
            displayArtist: track.displayArtist,
            displayTitle: track.displayTitle,
            bpm: track.bpm, camelot: track.camelot, key: track.key
        )
        item.setlist = set
        modelContext.insert(item)
        try? modelContext.save()
        candidateTrack = nil
    }

    private func createAndSelectNewSet() {
        let s = SetlistEntity()
        modelContext.insert(s)
        try? modelContext.save()
        activeSet = s
    }

    // MARK: - Sub-components

    @ViewBuilder
    private func camelotPill(_ code: String, fontSize: CGFloat) -> some View {
        Text(code)
            .font(.system(size: fontSize, weight: .bold).monospacedDigit())
            .foregroundStyle(CamelotColor.text(for: code))
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(Capsule().fill(CamelotColor.background(for: code)))
    }
}

// MARK: - Deck card (owns zoom state so zoom changes don't re-render MixModeView)

private struct DeckCardView: View {
    @Environment(AudioPlaybackController.self) private var playback

    let label: String
    let track: MixTrack?
    let coverURL: URL?
    let tintColor: Color
    var dismissable: Bool = false
    let onDismiss: () -> Void

    @State private var zoomFactor: Double = 1.0

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                AsyncImage(url: coverURL) { phase in
                    switch phase {
                    case .success(let img):
                        img.resizable().aspectRatio(contentMode: .fill)
                    default:
                        ZStack {
                            Color.secondary.opacity(0.1)
                            Image(systemName: "music.note").font(.system(size: 18)).foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(width: 68, height: 68)
                .clipShape(RoundedRectangle(cornerRadius: 6))

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) {
                        Text(label)
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(tintColor)
                            .kerning(0.3)
                        Spacer()
                        if dismissable, track != nil {
                            Button { onDismiss() } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 14))
                                    .foregroundStyle(Color.secondary.opacity(0.55))
                            }
                            .buttonStyle(.plain)
                        }
                        if let fp = track?.filePath { playButton(fp) }
                    }
                    if let t = track {
                        Text(t.displayTitle)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(t.displayArtist)
                            .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                        HStack(spacing: 5) {
                            camelotPill(t.camelot)
                            Text("\(Int(t.bpm.rounded())) BPM")
                                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                            if !t.key.isEmpty {
                                Text(t.key).font(.system(size: 10)).foregroundStyle(.secondary)
                            }
                            Spacer()
                            HStack(spacing: 3) {
                                Button {
                                    zoomFactor = zoomFactor == 16 ? 12 : (zoomFactor == 12 ? 8 : max(1, zoomFactor / 2))
                                } label: {
                                    Image(systemName: "minus")
                                        .font(.system(size: 9, weight: .semibold))
                                }
                                if zoomFactor > 1 {
                                    Text("\(Int(zoomFactor))×")
                                        .font(.system(size: 9, weight: .medium).monospacedDigit())
                                }
                                Button {
                                    zoomFactor = zoomFactor == 12 ? 16 : (zoomFactor == 8 ? 12 : min(16, zoomFactor * 2))
                                } label: {
                                    Image(systemName: "plus")
                                        .font(.system(size: 9, weight: .semibold))
                                }
                            }
                            .foregroundStyle(Color.secondary.opacity(0.7))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.black.opacity(0.25)))
                            .buttonStyle(.plain)
                        }
                    } else {
                        Text("—").font(.system(size: 13)).foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, minHeight: 88)

            if let fp = track?.filePath, !fp.isEmpty {
                TrackWaveformView(filePath: fp, zoomFactor: $zoomFactor)
                    .id(fp)
            } else {
                Color.clear.frame(height: 68)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(tintColor.opacity(0.07))
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(tintColor.opacity(0.18), lineWidth: 1))
        )
    }

    @ViewBuilder
    private func playButton(_ filePath: String) -> some View {
        Button { playback.play(filePath: filePath) } label: {
            let isActive  = playback.currentFilePath == filePath
            let isPlaying = isActive && playback.isPlaying
            Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                .font(.system(size: 15))
                .foregroundStyle(isActive ? Color.accentColor : Color.secondary.opacity(0.5))
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func camelotPill(_ code: String) -> some View {
        Text(code)
            .font(.system(size: 9, weight: .bold).monospacedDigit())
            .foregroundStyle(CamelotColor.text(for: code))
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(Capsule().fill(CamelotColor.background(for: code)))
    }
}

// MARK: - Harmonic strip tile

private struct StripTileView: View {
    let track: MixTrack
    let group: HarmonicGroup
    let thumbURL: URL?
    let releaseName: String?
    let isCandidate: Bool

    private var badgeLabel: String {
        switch group {
        case .perfectMatch: return "EXACT"
        case .energyBoost:  return "ENERGY+"
        case .energyDrop:   return "ENERGY−"
        case .moodSwitch:   return "MOOD"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                AsyncImage(url: thumbURL) { phase in
                    switch phase {
                    case .success(let img):
                        img.resizable().aspectRatio(contentMode: .fill)
                    default:
                        ZStack {
                            Color.secondary.opacity(0.12)
                            Image(systemName: "music.note").font(.system(size: 26)).foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(width: 176, height: 176)
                .clipped()

                Circle()
                    .fill(group.color)
                    .frame(width: 14, height: 14)
                    .overlay(Circle().strokeBorder(.white.opacity(0.7), lineWidth: 1))
                    .padding(6)
            }
            .frame(width: 176, height: 176)

            VStack(alignment: .leading, spacing: 3) {
                Text(track.displayTitle)
                    .font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Text(track.displayArtist)
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                if let release = releaseName {
                    Text("from \(release)")
                        .font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1)
                }
                HStack(spacing: 4) {
                    badge("\(Int(track.bpm.rounded()))", bg: Color(red: 0.15, green: 0.55, blue: 0.30))
                    badge(track.camelot, bg: Color(red: 0.15, green: 0.55, blue: 0.30))
                    badge(badgeLabel, bg: group.color.opacity(0.2), fg: group.color)
                }
            }
            .padding(8)
        }
        .frame(width: 176)
        .background(RoundedRectangle(cornerRadius: 10)
            .fill(isCandidate ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(isCandidate ? Color.accentColor.opacity(0.55) : Color.clear, lineWidth: 1.5))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private func badge(_ text: String, bg: Color, fg: Color = .white) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .bold).monospacedDigit())
            .foregroundStyle(fg)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(Capsule().fill(bg))
    }
}

// MARK: - Track picker sheet

struct TrackPickerSheet: View {
    let entity: CollectionItemEntity
    let onPick: (MixTrack) -> Void

    @Environment(\.dismiss) private var dismiss

    private var mixableTracks: [TrackEntity] {
        entity.tracks
            .filter { $0.effectiveBpm != nil && !($0.effectiveCamelot ?? "").isEmpty }
            .sorted { $0.position < $1.position }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entity.basicInformation?.title ?? "Release").font(.headline)
                    Text("\(mixableTracks.count) mixer-ready track\(mixableTracks.count == 1 ? "" : "s")")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }
            }
            .padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 12)

            Divider()

            if mixableTracks.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "waveform.slash").font(.system(size: 36)).foregroundStyle(.tertiary)
                    Text("No tracks with BPM and key data").foregroundStyle(.secondary)
                    Text("Run audio analysis to make tracks mixer-ready.")
                        .font(.caption).foregroundStyle(.tertiary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                List(mixableTracks, id: \.trackMBID) { track in
                    Button {
                        let mix = MixTrack(
                            displayArtist: track.artistCredit,
                            displayTitle:  track.title,
                            bpm:           track.effectiveBpm ?? 0,
                            camelot:       track.effectiveCamelot ?? "",
                            key:           track.effectiveKey ?? "",
                            source:        track.featureSource,
                            filePath:      track.primaryLocalFilePath
                        )
                        onPick(mix)
                        dismiss()
                    } label: {
                        HStack(spacing: 10) {
                            Text(track.position)
                                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 28, alignment: .trailing)
                            if let bpm = track.effectiveBpm, let cam = track.effectiveCamelot {
                                camelotPill(cam)
                                Text("\(Int(bpm.rounded()))")
                                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 32, alignment: .trailing)
                            }
                            VStack(alignment: .leading, spacing: 1) {
                                Text(track.title).font(.system(size: 13)).lineLimit(1)
                                if !track.artistCredit.isEmpty {
                                    Text(track.artistCredit)
                                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            Spacer()
                            Image(systemName: "plus.circle")
                                .font(.system(size: 14))
                                .foregroundStyle(Color.accentColor.opacity(0.7))
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowInsets(EdgeInsets(top: 3, leading: 12, bottom: 3, trailing: 12))
                }
                .listStyle(.plain)
            }
        }
        .frame(minWidth: 460, minHeight: 340)
    }

    @ViewBuilder
    private func camelotPill(_ code: String) -> some View {
        Text(code)
            .font(.system(size: 9, weight: .bold).monospacedDigit())
            .foregroundStyle(CamelotColor.text(for: code))
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(Capsule().fill(CamelotColor.background(for: code)))
    }
}
