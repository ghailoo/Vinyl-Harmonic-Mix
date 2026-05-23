import SwiftUI
import SwiftData

// MARK: - Unified track model (TrackEntity or LocalFileEntity source)

struct MixTrack: Identifiable, Equatable, Hashable, Sendable {
    let displayArtist: String
    let displayTitle: String
    let bpm: Double
    let camelot: String
    let key: String
    let source: TrackEntity.FeatureSource
    let filePath: String?

    var id: String { filePath ?? "\(displayArtist)|\(displayTitle)|\(bpm)" }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: MixTrack, rhs: MixTrack) -> Bool { lhs.id == rhs.id }

    // Precomputed integer key: 1A→0, 1B→1, 2A→2, … 12B→23
    var camelotSortKey: Int {
        guard let last = camelot.last, let num = Int(camelot.dropLast()) else { return Int.max }
        return (num - 1) * 2 + (last == "B" ? 1 : 0)
    }
}

// MARK: - Harmonic compatibility group

enum HarmonicGroup: String, CaseIterable {
    case perfectMatch = "Perfect match"
    case energyBoost  = "Energy boost"
    case energyDrop   = "Energy drop"
    case moodSwitch   = "Mood switch"

    var systemImage: String {
        switch self {
        case .perfectMatch: return "checkmark.circle.fill"
        case .energyBoost:  return "arrow.up.circle"
        case .energyDrop:   return "arrow.down.circle"
        case .moodSwitch:   return "arrow.left.arrow.right.circle"
        }
    }

    var color: Color {
        switch self {
        case .perfectMatch: return Color(red: 0.15, green: 0.55, blue: 0.30)
        case .energyBoost:  return .orange
        case .energyDrop:   return .blue
        case .moodSwitch:   return .purple
        }
    }
}

// MARK: - MixView

struct MixView: View {
    @Environment(AudioPlaybackController.self) private var playback

    @Query private var allTrackEntities: [TrackEntity]
    @Query(filter: #Predicate<LocalFileEntity> { $0.bpm > 0 })
    private var analyzedFiles: [LocalFileEntity]

    enum MixScope: String, CaseIterable {
        case confident   = "Confident"
        case allAnalyzed = "All analyzed"
    }

    enum MixSort: String, CaseIterable {
        case bpm     = "BPM"
        case camelot = "Camelot"
        case artist  = "Artist"
    }

    struct CompatibleItem: Identifiable {
        var id: String { track.id }
        let track: MixTrack
        let bpmDelta: Double
    }

    @State private var scope: MixScope = .confident
    @State private var sort: MixSort = .bpm
    @State private var searchQuery = ""
    @State private var selectedTrack: MixTrack? = nil
    @State private var bpmTolerance: Double = 6
    @State private var tracks: [MixTrack] = []
    @State private var displayedTracks: [MixTrack] = []

    var body: some View {
        HStack(spacing: 0) {
            leftPane
                .frame(width: 360)
            Divider()
            rightPane
                .frame(maxWidth: .infinity)
        }
        .onAppear { rebuildTracks() }
        .onChange(of: scope) { _, _ in selectedTrack = nil; rebuildTracks() }
        .onChange(of: allTrackEntities.count) { _, _ in
            if scope == .confident { rebuildTracks() }
        }
        .onChange(of: analyzedFiles.count) { _, _ in rebuildTracks() }
        .onChange(of: sort) { _, _ in refreshDisplay() }
        .onChange(of: searchQuery) { _, _ in refreshDisplay() }
        .onChange(of: selectedTrack) { _, newTrack in
            if let fp = newTrack?.filePath { playback.loadWaveformIfNeeded(filePath: fp) }
        }
    }

    // MARK: - Data

    private func rebuildTracks() {
        switch scope {
        case .confident:
            tracks = allTrackEntities
                .filter {
                    $0.fileMatchState == "confident" &&
                    $0.effectiveBpm != nil &&
                    !($0.effectiveCamelot ?? "").isEmpty
                }
                .map { t in
                    MixTrack(
                        displayArtist: t.artistCredit,
                        displayTitle:  t.title,
                        bpm:      t.effectiveBpm!,
                        camelot:  t.effectiveCamelot!,
                        key:      t.effectiveKey ?? "",
                        source:   t.featureSource,
                        filePath: t.primaryLocalFilePath
                    )
                }
        case .allAnalyzed:
            tracks = analyzedFiles
                .filter { !$0.camelot.isEmpty }
                .map { f in
                    MixTrack(
                        displayArtist: f.artistFolder.isEmpty ? f.parentFolder : f.artistFolder,
                        displayTitle:  URL(fileURLWithPath: f.filePath)
                            .deletingPathExtension().lastPathComponent,
                        bpm:      f.bpm,
                        camelot:  f.camelot,
                        key:      f.key.isEmpty ? "" : "\(f.key) \(f.scale)",
                        source:   .local,
                        filePath: f.filePath
                    )
                }
        }
        refreshDisplay()
    }

    private func refreshDisplay() {
        let snap = tracks
        let q = searchQuery.lowercased()
        let s = sort
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> [MixTrack] in
                var r = snap
                if !q.isEmpty {
                    r = r.filter {
                        $0.displayArtist.lowercased().contains(q) ||
                        $0.displayTitle.lowercased().contains(q)
                    }
                }
                switch s {
                case .bpm:
                    r.sort { $0.bpm < $1.bpm }
                case .camelot:
                    func camelotKey(_ t: MixTrack) -> Int {
                        guard let last = t.camelot.last,
                              let num  = Int(t.camelot.dropLast()) else { return Int.max }
                        return (num - 1) * 2 + (last == "B" ? 1 : 0)
                    }
                    r.sort { camelotKey($0) < camelotKey($1) }
                case .artist:
                    r.sort {
                        $0.displayArtist.localizedCaseInsensitiveCompare($1.displayArtist) == .orderedAscending
                    }
                }
                return r
            }.value
            displayedTracks = result
        }
    }

    private func compatibleGroups(for selected: MixTrack) -> [HarmonicGroup: [CompatibleItem]] {
        guard !selected.camelot.isEmpty else { return [:] }
        let compat = CamelotConverter.compatibleCodes(for: selected.camelot)
        // compat[0] = same number, other letter → mood switch
        // compat[1] = next number, same letter  → energy boost
        // compat[2] = prev number, same letter  → energy drop

        var result: [HarmonicGroup: [CompatibleItem]] = [:]
        for track in tracks {
            guard track.id != selected.id else { continue }
            let delta = track.bpm - selected.bpm
            guard abs(delta) <= bpmTolerance else { continue }

            let group: HarmonicGroup
            if track.camelot == selected.camelot {
                group = .perfectMatch
            } else if compat.count >= 3 && track.camelot == compat[1] {
                group = .energyBoost
            } else if compat.count >= 3 && track.camelot == compat[2] {
                group = .energyDrop
            } else if !compat.isEmpty && track.camelot == compat[0] {
                group = .moodSwitch
            } else {
                continue
            }

            result[group, default: []].append(CompatibleItem(track: track, bpmDelta: delta))
        }
        for key in result.keys {
            result[key]?.sort { abs($0.bpmDelta) < abs($1.bpmDelta) }
        }
        return result
    }

    // MARK: - Left pane

    private var leftPane: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                Picker("", selection: $scope) {
                    ForEach(MixScope.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 12))
                    TextField("Search artist, title…", text: $searchQuery)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                    if !searchQuery.isEmpty {
                        Button { searchQuery = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.1)))

                HStack {
                    Text("\(displayedTracks.count) tracks")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Picker("Sort", selection: $sort) {
                        ForEach(MixSort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(width: 90)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 8)

            Divider()

            List(displayedTracks, id: \.id, selection: $selectedTrack) { track in
                libraryRow(track).tag(track)
            }
            .listStyle(.plain)
        }
    }

    // MARK: - Right pane

    @ViewBuilder
    private var rightPane: some View {
        if let selected = selectedTrack {
            VStack(spacing: 0) {
                // Selected track header
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 10) {
                        camelotPill(selected.camelot, fontSize: 12)
                        Text("\(Int(selected.bpm.rounded())) BPM")
                            .font(.system(size: 14, weight: .semibold).monospacedDigit())
                        if !selected.key.isEmpty {
                            Text(selected.key)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        sourceLabel(selected.source)
                        if let fp = selected.filePath {
                            playButton(fp, fontSize: 18)
                        }
                    }
                    Text(selected.displayTitle)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                    Text(selected.displayArtist)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.06))

                Divider()

                // Waveform for the selected track
                if let fp = selected.filePath {
                    SelectedTrackWaveformView(filePath: fp)
                    Divider()
                }

                // BPM tolerance slider
                HStack(spacing: 10) {
                    Text("BPM window")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Slider(value: $bpmTolerance, in: 0...15, step: 1)
                        .controlSize(.small)
                    Text("±\(Int(bpmTolerance))")
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .frame(width: 28, alignment: .trailing)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

                Divider()

                // Compatible tracks grouped by harmonic relationship
                let grouped = compatibleGroups(for: selected)
                let totalCount = grouped.values.reduce(0) { $0 + $1.count }

                if totalCount == 0 {
                    VStack(spacing: 12) {
                        Spacer()
                        Image(systemName: "waveform.slash")
                            .font(.system(size: 36))
                            .foregroundStyle(.tertiary)
                        Text("No compatible tracks within ±\(Int(bpmTolerance)) BPM")
                            .foregroundStyle(.secondary)
                        Text("Widen the BPM window or try a different scope")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    List {
                        ForEach(HarmonicGroup.allCases, id: \.self) { group in
                            if let items = grouped[group], !items.isEmpty {
                                Section {
                                    ForEach(items) { item in
                                        compatibleRow(item)
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
        } else {
            // Placeholder when nothing is selected
            VStack(spacing: 14) {
                Spacer()
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 44))
                    .foregroundStyle(.tertiary)
                Text("Select a track to find harmonic matches")
                    .foregroundStyle(.secondary)
                Text("\(displayedTracks.count) tracks with harmonic data")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Row views

    @ViewBuilder
    private func libraryRow(_ track: MixTrack) -> some View {
        HStack(spacing: 8) {
            if let fp = track.filePath {
                playButton(fp, fontSize: 14)
            } else {
                Image(systemName: "slash.circle")
                    .font(.system(size: 14))
                    .foregroundStyle(.quaternary)
            }
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
            Spacer(minLength: 4)
            sourceLabel(track.source)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func compatibleRow(_ item: CompatibleItem) -> some View {
        HStack(spacing: 8) {
            if let fp = item.track.filePath {
                playButton(fp, fontSize: 14)
            } else {
                Image(systemName: "slash.circle")
                    .font(.system(size: 14))
                    .foregroundStyle(.quaternary)
            }
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
            sourceLabel(item.track.source)
        }
        .padding(.vertical, 2)
    }

    // MARK: - Shared sub-components

    @ViewBuilder
    private func playButton(_ filePath: String, fontSize: CGFloat) -> some View {
        Button {
            playback.play(filePath: filePath)
        } label: {
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

    @ViewBuilder
    private func sourceLabel(_ source: TrackEntity.FeatureSource) -> some View {
        switch source {
        case .local:
            Text("ES")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color(red: 0.15, green: 0.55, blue: 0.30)))
        case .ab:
            Text("AB")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color(red: 0.35, green: 0.45, blue: 0.65)))
        case .none:
            EmptyView()
        }
    }
}

// MARK: - Selected-track waveform (own @Observable context so currentTime drives live progress)

private struct SelectedTrackWaveformView: View {
    @Environment(AudioPlaybackController.self) private var playback
    let filePath: String

    var body: some View {
        let isActive = playback.currentFilePath == filePath
        let progress: Double = isActive && playback.duration > 0
            ? min(1, max(0, playback.currentTime / playback.duration))
            : 0.0

        VStack(alignment: .leading, spacing: 4) {
            switch playback.waveformState(for: filePath) {
            case .ready(let peaks):
                WaveformView(peaks: peaks, progress: progress) { fraction in
                    playback.seek(toFraction: fraction)
                }
                .clipShape(RoundedRectangle(cornerRadius: 4))
            case .loading:
                ZStack {
                    RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.1))
                    HStack(spacing: 6) {
                        ProgressView().scaleEffect(0.6)
                        Text("Loading waveform…").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            case .failed:
                ZStack {
                    RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.08))
                    Text("Waveform unavailable").font(.caption2).foregroundStyle(.tertiary)
                }
            case .idle:
                Color.clear
                    .onAppear { playback.loadWaveformIfNeeded(filePath: filePath) }
            }

            if isActive && playback.duration > 0 {
                Text("\(formatTime(playback.currentTime)) / \(formatTime(playback.duration))")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .frame(height: 52)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func formatTime(_ seconds: Double) -> String {
        let s = max(0, Int(seconds))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
