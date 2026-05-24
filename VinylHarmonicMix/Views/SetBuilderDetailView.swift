import SwiftUI
import SwiftData
import AppKit

struct SetBuilderDetailView: View {
    let setlist: SetlistEntity

    @Environment(\.modelContext) private var modelContext
    @Environment(AudioPlaybackController.self) private var playback

    @Query(filter: #Predicate<LocalFileEntity> { $0.bpm > 0 })
    private var analyzedFiles: [LocalFileEntity]

    @State private var pool: [MixTrack] = []
    @State private var bpmTolerance: Double = 6
    @State private var candidateTrack: MixTrack? = nil
    @State private var startSearchQuery: String = ""
    @State private var filteredPool: [MixTrack] = []

    // Play-through
    @State private var isPlayingThrough: Bool = false
    @State private var playThroughIndex: Int = 0

    // Export feedback
    @State private var showCopiedFeedback: Bool = false

    // Compatibility group filter (nil = All)
    @State private var groupFilter: HarmonicGroup? = nil

    // "Pick any track" hard-cut picker
    @State private var showAnyTrackPicker: Bool = false
    @State private var anyTrackQuery: String = ""
    @State private var filteredAnyTrackPool: [MixTrack] = []

    // MARK: - Computed

    private var sortedItems: [SetlistItemEntity] {
        setlist.items.sorted { $0.position < $1.position }
    }

    private var anchorTrack: MixTrack? {
        guard let last = sortedItems.last else { return nil }
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

    private var journeySummary: String {
        let items = sortedItems
        guard !items.isEmpty else { return "" }
        let bpms = items.map { $0.bpm }
        let lo = Int((bpms.min() ?? 0).rounded())
        let hi = Int((bpms.max() ?? 0).rounded())
        let bpmStr = lo == hi ? "\(lo) BPM" : "\(lo)–\(hi) BPM"
        let camelotPath = items.map { $0.camelot }.joined(separator: " → ")
        return "\(bpmStr) · \(camelotPath)"
    }

    private var displayGroups: [HarmonicGroup] {
        if let f = groupFilter { return [f] } else { return HarmonicGroup.allCases }
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            if !sortedItems.isEmpty {
                journeyPanel
                Divider()
            }
            if sortedItems.isEmpty {
                pickStartView
            } else {
                builderView
            }
        }
        .onAppear { buildPool() }
        .onChange(of: analyzedFiles.count) { _, _ in buildPool() }
        .onChange(of: startSearchQuery) { _, _ in filterStartPool() }
        .onChange(of: anyTrackQuery) { _, _ in filterAnyTrackPool() }
        .onChange(of: candidateTrack) { _, newVal in
            if let fp = newVal?.filePath {
                playback.loadWaveformIfNeeded(filePath: fp)
            }
        }
        .onChange(of: playback.playbackFinishedCount) { _, _ in
            guard isPlayingThrough else { return }
            advancePlayThrough()
        }
    }

    // MARK: - Pool

    private func buildPool() {
        pool = MixTrackPool.allAnalyzed(from: analyzedFiles)
        filterStartPool()
    }

    private func filterStartPool() {
        let q = startSearchQuery.lowercased()
        let snap = pool
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> [MixTrack] in
                guard !q.isEmpty else { return snap }
                return snap.filter {
                    $0.displayArtist.lowercased().contains(q) ||
                    $0.displayTitle.lowercased().contains(q)
                }
            }.value
            filteredPool = result
        }
    }

    private func filterAnyTrackPool() {
        let q = anyTrackQuery.lowercased()
        let snap = pool
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> [MixTrack] in
                guard !q.isEmpty else { return snap }
                return snap.filter {
                    $0.displayArtist.lowercased().contains(q) ||
                    $0.displayTitle.lowercased().contains(q)
                }
            }.value
            filteredAnyTrackPool = result
        }
    }

    // MARK: - Transition helper

    private func transitionInfo(from: SetlistItemEntity, to: SetlistItemEntity) -> TransitionInfo {
        VinylHarmonicMix.transitionInfo(fromCamelot: from.camelot, fromBPM: from.bpm,
                                        toCamelot: to.camelot, toBPM: to.bpm)
    }

    // MARK: - Journey panel

    private var journeyPanel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    let count = sortedItems.count
                    Text("\(count) track\(count == 1 ? "" : "s")")
                        .font(.system(size: 11, weight: .semibold))
                    Text(journeySummary)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Button(action: isPlayingThrough ? stopPlayThrough : startPlayThrough) {
                    Label(isPlayingThrough ? "Stop" : "Play Set",
                          systemImage: isPlayingThrough ? "stop.fill" : "play.fill")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button(action: copyTracklist) {
                    Label(showCopiedFeedback ? "Copied!" : "Copy Tracklist",
                          systemImage: showCopiedFeedback ? "checkmark" : "doc.on.clipboard")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(showCopiedFeedback)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.secondary.opacity(0.04))

            Divider()

            List {
                ForEach(Array(sortedItems.enumerated()), id: \.element.persistentModelID) { idx, item in
                    trackRow(item: item, idx: idx)
                        .listRowInsets(EdgeInsets(top: 2, leading: 12, bottom: 2, trailing: 10))
                }
                .onMove { from, to in reorderItems(from: from, to: to) }
            }
            .listStyle(.plain)
            .frame(maxHeight: 280)
        }
    }

    // MARK: - Track row

    @ViewBuilder
    private func trackRow(item: SetlistItemEntity, idx: Int) -> some View {
        let items = sortedItems
        let total = items.count
        let isNowPlaying = isPlayingThrough
            && !item.filePath.isEmpty
            && playback.currentFilePath == item.filePath

        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("\(idx + 1)")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 20, alignment: .trailing)
                camelotPill(item.camelot, fontSize: 9)
                Text("\(Int(item.bpm.rounded()))")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 28, alignment: .trailing)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.displayTitle)
                        .font(.system(size: 12))
                        .lineLimit(1)
                    Text(item.displayArtist)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if isNowPlaying {
                    Image(systemName: playback.isPlaying ? "speaker.wave.2.fill" : "speaker.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.accentColor)
                        .symbolEffect(.variableColor, isActive: playback.isPlaying)
                }
                if idx == total - 1 {
                    Text("anchor")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.accentColor))
                }
                Button(role: .destructive) { removeItem(item) } label: {
                    Image(systemName: "minus.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.red.opacity(0.65))
                }
                .buttonStyle(.plain)
                .help("Remove from set")
            }
            .padding(.vertical, 4)

            if idx < total - 1 {
                let next = items[idx + 1]
                let info = transitionInfo(from: item, to: next)
                HStack(spacing: 6) {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.25))
                        .frame(width: 1, height: 10)
                        .padding(.leading, 23)
                    Text("\(info.bpmDelta) · \(info.label)")
                        .font(.system(size: 10))
                        .foregroundStyle(info.group?.color ?? Color.secondary.opacity(0.7))
                }
                .padding(.bottom, 2)
            }
        }
        .listRowBackground(isNowPlaying ? Color.accentColor.opacity(0.07) : Color.clear)
    }

    // MARK: - Pick-start view (empty set)

    private var pickStartView: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 12))
                TextField("Search to pick a start track…", text: $startSearchQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                if !startSearchQuery.isEmpty {
                    Button { startSearchQuery = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.secondary.opacity(0.06))

            Divider()

            if pool.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    ProgressView()
                    Text("Loading analyzed tracks…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let displayPool = startSearchQuery.isEmpty ? pool : filteredPool
                List(displayPool, id: \.id) { track in
                    Button(action: { pickStartTrack(track) }) {
                        HStack(spacing: 8) {
                            camelotPill(track.camelot, fontSize: 9)
                            Text("\(Int(track.bpm.rounded()))")
                                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                                .frame(width: 30, alignment: .trailing)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(track.displayTitle)
                                    .font(.system(size: 13))
                                    .lineLimit(1)
                                Text(track.displayArtist)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.plain)
            }
        }
    }

    // MARK: - Builder view (non-empty set)

    private var builderView: some View {
        VStack(spacing: 0) {
            // Two-deck panel + transition bubble between them
            HStack(alignment: .center, spacing: 6) {
                deckPanel(label: "DECK A — ANCHOR", track: anchorTrack)
                if let anchor = anchorTrack, let candidate = candidateTrack {
                    TransitionBubbleView(anchor: anchor, candidate: candidate)
                } else {
                    Color.clear.frame(width: 62)
                }
                deckPanel(label: "DECK B — NEXT", track: candidateTrack)
            }
            .padding(12)

            Divider()

            // BPM window + Add to Set
            HStack(spacing: 10) {
                Text("BPM window")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Slider(value: $bpmTolerance, in: 0...15, step: 1)
                    .controlSize(.small)
                Text("±\(Int(bpmTolerance))")
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .frame(width: 28, alignment: .trailing)
                Spacer()
                Button("Add to Set") { addCandidateToSet() }
                    .buttonStyle(.borderedProminent)
                    .disabled(candidateTrack == nil)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            Divider()

            // Group filter + "Pick any track" toggle
            HStack(spacing: 8) {
                Picker("Filter", selection: $groupFilter) {
                    Text("All").tag(HarmonicGroup?.none)
                    ForEach(HarmonicGroup.allCases, id: \.self) { group in
                        Text(group.shortName).tag(HarmonicGroup?.some(group))
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .opacity(showAnyTrackPicker ? 0.4 : 1.0)
                .disabled(showAnyTrackPicker)

                if showAnyTrackPicker {
                    Button(action: { showAnyTrackPicker = false; anyTrackQuery = "" }) {
                        Label("Harmonic", systemImage: "slider.horizontal.3")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                } else {
                    Button(action: { showAnyTrackPicker = true }) {
                        Label("Any track", systemImage: "scissors")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            Divider()

            if showAnyTrackPicker {
                anyTrackPickerPanel
            } else {
                suggestionsPanel
            }
        }
    }

    @ViewBuilder
    private func deckPanel(label: String, track: MixTrack?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .kerning(0.5)
            if let t = track {
                HStack(spacing: 6) {
                    camelotPill(t.camelot, fontSize: 9)
                    Text("\(Int(t.bpm.rounded())) BPM")
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    if !t.key.isEmpty {
                        Text(t.key)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let fp = t.filePath {
                        playButton(fp, fontSize: 16)
                    }
                }
                Text(t.displayTitle)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Text(t.displayArtist)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let fp = t.filePath {
                    TrackWaveformView(filePath: fp)
                        .id(fp)
                        .padding(.horizontal, -16)
                }
            } else {
                Text("—")
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: 52)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06)))
    }

    // MARK: - Any-track picker (hard-cut option)

    private var anyTrackPickerPanel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 12))
                TextField("Search all \(pool.count) analyzed tracks…", text: $anyTrackQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                if !anyTrackQuery.isEmpty {
                    Button { anyTrackQuery = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.secondary.opacity(0.06))

            Divider()

            let displayPool = anyTrackQuery.isEmpty ? pool : filteredAnyTrackPool
            List(displayPool, id: \.id) { track in
                Button(action: {
                    candidateTrack = track
                    showAnyTrackPicker = false
                    anyTrackQuery = ""
                }) {
                    HStack(spacing: 8) {
                        camelotPill(track.camelot, fontSize: 9)
                        Text("\(Int(track.bpm.rounded()))")
                            .font(.system(size: 12, weight: .semibold).monospacedDigit())
                            .frame(width: 30, alignment: .trailing)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(track.displayTitle)
                                .font(.system(size: 13))
                                .lineLimit(1)
                            Text(track.displayArtist)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
        }
    }

    // MARK: - Suggestions panel (harmonic, respects groupFilter)

    @ViewBuilder
    private var suggestionsPanel: some View {
        if let anchor = anchorTrack {
            let allGrouped = HarmonicCompatibility.compatibleGroups(for: anchor, in: pool, bpmTolerance: bpmTolerance)
            let groups = displayGroups
            let totalCount = groups.reduce(0) { $0 + (allGrouped[$1]?.count ?? 0) }

            if totalCount == 0 {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "waveform.slash")
                        .font(.system(size: 32))
                        .foregroundStyle(.tertiary)
                    if let f = groupFilter {
                        Text("No \(f.rawValue.lowercased()) tracks within ±\(Int(bpmTolerance)) BPM")
                            .foregroundStyle(.secondary)
                    } else {
                        Text("No compatible tracks within ±\(Int(bpmTolerance)) BPM")
                            .foregroundStyle(.secondary)
                    }
                    Text("Widen the BPM window or use Any track")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                List {
                    ForEach(groups, id: \.self) { group in
                        if let items = allGrouped[group], !items.isEmpty {
                            Section {
                                ForEach(items) { item in
                                    suggestionRow(item)
                                }
                            } header: {
                                HStack(spacing: 5) {
                                    Image(systemName: group.systemImage)
                                        .foregroundStyle(group.color)
                                    Text(group.rawValue)
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(group.color)
                                    Text("· \(items.count)")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private func suggestionRow(_ item: CompatibleItem) -> some View {
        let isSelected = candidateTrack?.id == item.track.id
        HStack(spacing: 8) {
            camelotPill(item.track.camelot, fontSize: 9)
            HStack(spacing: 2) {
                Text("\(Int(item.track.bpm.rounded()))")
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                let deltaInt = Int(item.bpmDelta.rounded())
                let sign = deltaInt >= 0 ? "+" : ""
                Text("\(sign)\(deltaInt)")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(abs(item.bpmDelta) < 0.5 ? .green : .secondary)
            }
            .frame(width: 52, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.track.displayTitle)
                    .font(.system(size: 13))
                    .lineLimit(1)
                Text(item.track.displayArtist)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if let fp = item.track.filePath {
                playButton(fp, fontSize: 14)
            }
            Image(systemName: isSelected ? "b.circle.fill" : "chevron.right.circle")
                .font(.system(size: 14))
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.4))
        }
        .padding(.vertical, 2)
        .listRowBackground(isSelected ? Color.accentColor.opacity(0.08) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { candidateTrack = item.track }
    }

    // MARK: - Play-through

    private func startPlayThrough() {
        guard !sortedItems.isEmpty else { return }
        playThroughIndex = 0
        isPlayingThrough = true
        playItemAt(0)
    }

    private func stopPlayThrough() {
        isPlayingThrough = false
        playback.pause()
    }

    private func advancePlayThrough() {
        let items = sortedItems
        var next = playThroughIndex + 1
        while next < items.count && items[next].filePath.isEmpty {
            next += 1
        }
        if next < items.count {
            playThroughIndex = next
            playItemAt(next)
        } else {
            isPlayingThrough = false
            playThroughIndex = 0
        }
    }

    private func playItemAt(_ idx: Int) {
        let items = sortedItems
        guard idx < items.count, !items[idx].filePath.isEmpty else { return }
        playback.play(filePath: items[idx].filePath)
    }

    // MARK: - Reorder + Remove

    private func reorderItems(from source: IndexSet, to destination: Int) {
        var items = sortedItems
        items.move(fromOffsets: source, toOffset: destination)
        for (newPos, item) in items.enumerated() {
            item.position = newPos
        }
        try? modelContext.save()
        if isPlayingThrough { stopPlayThrough() }
    }

    private func removeItem(_ item: SetlistItemEntity) {
        let remaining = sortedItems.filter { $0.persistentModelID != item.persistentModelID }
        if candidateTrack?.filePath == item.filePath { candidateTrack = nil }
        modelContext.delete(item)
        for (newPos, track) in remaining.enumerated() {
            track.position = newPos
        }
        try? modelContext.save()
        if isPlayingThrough && remaining.isEmpty { stopPlayThrough() }
    }

    // MARK: - Text export

    private func copyTracklist() {
        let items = sortedItems
        var lines = [setlist.name]
        for (i, item) in items.enumerated() {
            lines.append("\(i + 1). \(item.displayArtist) – \(item.displayTitle) (\(Int(item.bpm.rounded())) BPM, \(item.camelot))")
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
        showCopiedFeedback = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            showCopiedFeedback = false
        }
    }

    // MARK: - Actions

    private func pickStartTrack(_ track: MixTrack) {
        let item = SetlistItemEntity(
            position: 0,
            filePath: track.filePath ?? "",
            displayArtist: track.displayArtist,
            displayTitle: track.displayTitle,
            bpm: track.bpm,
            camelot: track.camelot,
            key: track.key
        )
        item.setlist = setlist
        modelContext.insert(item)
        try? modelContext.save()
    }

    private func addCandidateToSet() {
        guard let track = candidateTrack else { return }
        let nextPosition = (sortedItems.map(\.position).max() ?? -1) + 1
        let item = SetlistItemEntity(
            position: nextPosition,
            filePath: track.filePath ?? "",
            displayArtist: track.displayArtist,
            displayTitle: track.displayTitle,
            bpm: track.bpm,
            camelot: track.camelot,
            key: track.key
        )
        item.setlist = setlist
        modelContext.insert(item)
        try? modelContext.save()
        candidateTrack = nil
    }

    // MARK: - Shared sub-components

    @ViewBuilder
    private func playButton(_ filePath: String, fontSize: CGFloat) -> some View {
        Button { playback.play(filePath: filePath) } label: {
            let isActive  = playback.currentFilePath == filePath
            let isPlaying = isActive && playback.isPlaying
            Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                .font(.system(size: fontSize))
                .foregroundStyle(isActive ? Color.accentColor : Color.secondary.opacity(0.5))
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func camelotPill(_ code: String, fontSize: CGFloat) -> some View {
        Text(code)
            .font(.system(size: fontSize, weight: .bold).monospacedDigit())
            .foregroundStyle(CamelotColor.text(for: code))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Capsule().fill(CamelotColor.background(for: code)))
    }
}
