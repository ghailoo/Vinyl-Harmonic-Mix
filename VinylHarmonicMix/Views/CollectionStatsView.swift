import SwiftUI
import SwiftData
import Combine

struct CollectionStatsView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(DetailCacheCoordinator.self) private var cacheCoordinator
    @Environment(RecordingsScanCoordinator.self) private var recordingsCoordinator
    @Environment(AudioFeaturesScanCoordinator.self) private var audioFeaturesCoordinator
    @Environment(FileMatchCoordinator.self) private var fileMatchCoordinator
    @Environment(LocalAnalysisCoordinator.self) private var localAnalysisCoordinator
    @Environment(CueDetectionCoordinator.self) private var cueCoordinator
    @Environment(CollectionViewModel.self) private var viewModel

    @State private var showRefreshAlert = false

    // MARK: - "Show all" disclosure state (B4)
    @State private var showAllFormats = false
    @State private var showAllGenres = false
    @State private var showAllDecades = false
    @State private var showAllLabels = false
    @State private var showAllArtists = false

    // Every number on this page comes from CollectionViewModel.stats, computed off the main
    // actor and kept across sidebar switches — no @Query here, so a rebuild fetches nothing.
    private var stats: CollectionStats { viewModel.stats ?? CollectionStats() }

    var body: some View {
        PerfLog.begin("CollectionStatsView.body")
        defer { PerfLog.end("CollectionStatsView.body") }
        return Group {
            if viewModel.stats == nil {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if stats.releaseCount == 0 {
                VStack(spacing: 12) {
                    Image(systemName: "tray")
                        .font(.iconHero)
                        .foregroundStyle(.secondary)
                    Text("Import your collection first.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 0) {
                    if cacheCoordinator.shouldShowPanel {
                        DetailCachePanelView(coordinator: cacheCoordinator)
                            .padding(.horizontal, 24)
                            .padding(.top, 12)
                            .padding(.bottom, 8)
                            .frame(maxWidth: .infinity)
                            .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                    }
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            Text("Stats")
                                .font(.largeTitle.weight(.bold))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.bottom, 4)

                            summaryTilesRow

                            pipelineCard

                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 420), spacing: 14)], alignment: .leading, spacing: 14) {
                                if !stats.formatCounts.isEmpty  { formatCard }
                                if !stats.genreCounts.isEmpty   { genreCard }
                                if !stats.decadeCounts.isEmpty  { decadeCard }
                                if !stats.labelCounts.isEmpty   { labelsCard }
                                if !stats.artistCounts.isEmpty  { artistsCard }
                            }
                        }
                        .padding(.horizontal, 24)
                        .padding(.vertical, 20)
                    }
                }
                .animation(reduceMotion ? nil : .snappy, value: cacheCoordinator.shouldShowPanel)
            }
        }
        .navigationTitle("Stats")
        .onAppear { viewModel.refreshStats(full: true) }
        // Replaces the old @Query liveness: any context's save (scans, analysis, caching)
        // refreshes the snapshot off-main while this page is on screen.
        .onReceive(NotificationCenter.default.publisher(for: ModelContext.didSave)
            .debounce(for: .milliseconds(500), scheduler: RunLoop.main)) { _ in
            viewModel.refreshStats(full: false)
        }
        .task {
            PerfLog.begin("CollectionStatsView.recomputeFileScope")
            localAnalysisCoordinator.recomputeFileScope()
            PerfLog.end("CollectionStatsView.recomputeFileScope")
        }
        .alert("Refresh all cached details?", isPresented: $showRefreshAlert) {
            Button("Refresh (~15 min)", role: .destructive) { cacheCoordinator.startRefresh() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All \(stats.releaseCount.formatted()) releases are already cached. Re-fetching will overwrite existing data and take approximately 15 minutes.")
        }
    }

    // MARK: - Card wrapper

    private func sectionCard<Content: View>(accent: Bool = false, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .padding(16)
        .background(
            accent ? Color.accentColor.opacity(0.05) : Color.secondary.opacity(0.045),
            in: RoundedRectangle(cornerRadius: 12)
        )
    }

    // MARK: - Progress row (shared by every stats section)

    /// One "N of M <noun> (P%)" line plus a matching bar. `isComplete` picks the fill color —
    /// accent while work remains, green once done — so every section reads the same way instead
    /// of the mix of one-off colors/phrasings each card used to hand-roll.
    private func progressRow(count: Int, total: Int, noun: String) -> some View {
        let pct = total > 0 ? min(100, count * 100 / total) : 0
        let isComplete = total > 0 && count >= total
        return VStack(alignment: .leading, spacing: 8) {
            Text("\(count.formatted()) of \(total.formatted()) \(noun) (\(pct)%)")
                .font(.body)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.15)).frame(height: 8)
                    Capsule()
                        .fill(isComplete ? Color.green : Color.accentColor)
                        .frame(
                            width: total > 0 ? geo.size.width * CGFloat(min(count, total)) / CGFloat(total) : 0,
                            height: 8
                        )
                }
            }
            .frame(height: 8)
        }
    }

    // MARK: - Section header

    private func sectionHeader(title: String) -> some View {
        Text(title)
            .font(.title2.weight(.semibold))
            .padding(.bottom, 10)
    }

    // MARK: - Summary tiles (B1)

    private var tracksTileValue: Int {
        stats.decodedTrackCount > 0 ? stats.decodedTrackCount : stats.trackCount
    }

    private var summaryTilesRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 16) {
                statTile(value: stats.releaseCount.formatted(), label: "releases", accent: false)
                statTile(value: tracksTileValue.formatted(), label: "tracks", accent: false)
                statTile(value: fileMatchCoordinator.confidentFileCount.formatted(), label: "matched files", accent: true)
                statTile(value: stats.analyzedLocalFileCount.formatted(), label: "analyzed", accent: true)
            }
            Text("\(yearRangeLabel) · median age \(medianAge > 0 ? "\(medianAge)y" : "—")")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func statTile(value: String, label: String, accent: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.statValue.monospacedDigit())
                .foregroundStyle(accent ? Color.accentColor : Color.primary)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Shared breakdown bar row (B3)
    //
    // One row shape — label · short bar · count right after the bar — reused by every
    // breakdown card below instead of each hand-rolling its own label/Spacer/count HStack.
    private func breakdownRow(rank: Int? = nil, icon: String? = nil, label: String, count: Int, maxCount: Int) -> some View {
        HStack(spacing: 10) {
            if let rank {
                Text("\(rank)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .frame(width: 16, alignment: .trailing)
            }
            if let icon {
                Image(systemName: icon)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(width: 16, alignment: .center)
            }
            Text(label)
                .font(.body)
                .lineLimit(1)
                .frame(width: 110, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.15)).frame(height: 6)
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(
                            width: maxCount > 0 ? geo.size.width * CGFloat(count) / CGFloat(maxCount) : 0,
                            height: 6
                        )
                }
            }
            .frame(height: 6)
            Text(count.formatted())
                .font(.body.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
        }
    }

    /// "Show all N" / "Show less" toggle under a top-5-truncated breakdown list (B4).
    @ViewBuilder
    private func showAllToggle(total: Int, isExpanded: Binding<Bool>) -> some View {
        if total > 5 {
            Button(isExpanded.wrappedValue ? "Show less" : "Show all \(total)") {
                isExpanded.wrappedValue.toggle()
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(Color.accentColor)
            .padding(.top, 8)
        }
    }

    // MARK: - Format card

    private var formatCard: some View {
        let all = stats.formatCounts
        let shown = showAllFormats ? all : Array(all.prefix(5))
        let maxCount = all.map(\.count).max() ?? 1
        return sectionCard {
            sectionHeader(title: "Releases by format")
            VStack(spacing: 8) {
                ForEach(Array(shown.enumerated()), id: \.offset) { _, item in
                    breakdownRow(icon: formatIcon(for: item.label), label: item.label, count: item.count, maxCount: maxCount)
                }
            }
            showAllToggle(total: all.count, isExpanded: $showAllFormats)
        }
    }

    private func formatIcon(for name: String) -> String {
        let lower = name.lowercased()
        if lower.contains("vinyl") || lower.contains("lp") || lower.contains("ep")
            || lower == "12\"" || lower == "10\"" || lower == "7\"" { return "circle.dotted" }
        if lower.contains("cd") || lower.contains("optical") { return "opticaldisc" }
        if lower.contains("cassette") || lower.contains("tape") { return "mediastick" }
        if lower.contains("box") || lower.contains("set") { return "square.stack.3d.up" }
        if lower.contains("file") || lower.contains("digital")
            || lower.contains("mp3") || lower.contains("flac") { return "waveform" }
        return "square"
    }

    // MARK: - Genre card

    private var genreCard: some View {
        let all = stats.genreCounts
        let shown = showAllGenres ? all : Array(all.prefix(5))
        let maxCount = all.map(\.count).max() ?? 1
        return sectionCard {
            sectionHeader(title: "Releases by genre")
            VStack(spacing: 8) {
                ForEach(Array(shown.enumerated()), id: \.offset) { _, item in
                    breakdownRow(label: item.label, count: item.count, maxCount: maxCount)
                }
            }
            showAllToggle(total: all.count, isExpanded: $showAllGenres)
        }
    }

    // MARK: - Decade card

    private var decadeCard: some View {
        // Chronological, not ranked by count — decades are a bounded timeline, so unlike
        // the other breakdowns there's no long tail to truncate with a "Show all" toggle.
        let items = stats.decadeCounts
        let maxCount = items.map(\.count).max() ?? 1
        return sectionCard {
            sectionHeader(title: "Releases by decade")
            VStack(spacing: 8) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    breakdownRow(label: item.label, count: item.count, maxCount: maxCount)
                }
            }
        }
    }

    // MARK: - Labels card

    private var labelsCard: some View {
        let all = stats.labelCounts
        let shown = showAllLabels ? all : Array(all.prefix(5))
        let maxCount = all.map(\.count).max() ?? 1
        return sectionCard {
            sectionHeader(title: "Top labels by releases")
            VStack(spacing: 8) {
                ForEach(Array(shown.enumerated()), id: \.offset) { index, item in
                    breakdownRow(rank: index + 1, label: item.label, count: item.count, maxCount: maxCount)
                }
            }
            showAllToggle(total: all.count, isExpanded: $showAllLabels)
        }
    }

    // MARK: - Artists card

    private var artistsCard: some View {
        let all = stats.artistCounts
        let shown = showAllArtists ? all : Array(all.prefix(5))
        let maxCount = all.map(\.count).max() ?? 1
        return sectionCard {
            sectionHeader(title: "Top artists by releases")
            VStack(spacing: 8) {
                ForEach(Array(shown.enumerated()), id: \.offset) { index, item in
                    breakdownRow(rank: index + 1, label: item.label, count: item.count, maxCount: maxCount)
                }
            }
            showAllToggle(total: all.count, isExpanded: $showAllArtists)
        }
    }

    // MARK: - Pipeline card (B5)
    //
    // The six pipeline progress sections used to be six separate cards scattered down the
    // page; grouped into one card near the top so the whole ingest pipeline reads at a glance.
    private var pipelineCard: some View {
        sectionCard {
            tracksCard
            Divider().padding(.vertical, 14)
            recordingsCard
            Divider().padding(.vertical, 14)
            localFilesCard
            Divider().padding(.vertical, 14)
            localAnalysisCard
            Divider().padding(.vertical, 14)
            audioFeaturesCard
            Divider().padding(.vertical, 14)
            cueDetectionCard
        }
    }

    // MARK: - Tracks card

    private var cacheIsEffectivelyComplete: Bool {
        guard stats.releaseCount > 0 else { return false }
        return stats.decodedDetailCount >= Int(Double(stats.releaseCount) * 0.95)
    }

    private var tracksCard: some View {
        let cachedCount = stats.detailRowCount
        let totalCount = stats.releaseCount
        let allCached = cachedCount >= totalCount && totalCount > 0
        let effectivelyComplete = cacheIsEffectivelyComplete
        let uncachedCount = max(0, totalCount - cachedCount)
        let isRunning: Bool = {
            switch cacheCoordinator.phase {
            case .scanning, .paused: return true
            default: return false
            }
        }()

        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text("Tracks & duration")
                    .font(.title2.weight(.semibold))
                if stats.decodedDetailCount > 0 && !effectivelyComplete {
                    HStack(spacing: 4) {
                        Image(systemName: "info.circle").font(.caption)
                        Text("Partial data").font(.caption)
                    }
                    .foregroundStyle(.tertiary)
                }
                Spacer()
            }
            .padding(.bottom, 12)

            if stats.decodedDetailCount == 0 {
                Text("No detail data yet. Cache all releases to see tracklists, duration, and credits (~15 min).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    if allCached {
                        Text("\(stats.decodedTrackCount.formatted()) tracks across all \(totalCount.formatted()) releases")
                            .font(.body)
                    } else {
                        Text("\(stats.decodedTrackCount.formatted()) tracks across \(stats.decodedDetailCount.formatted()) of \(totalCount.formatted()) releases (\(cachePercent)%)")
                            .font(.body)
                        if !effectivelyComplete, let est = estimatedTotalTracks {
                            Text("Estimated total: \(est.formatted()) tracks (extrapolated)")
                                .font(.body)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text("Recorded duration: \(cachedDurationLabel) (from cached data)")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
            }

            Button(
                isRunning           ? "Caching…" :
                allCached           ? "Refresh detail cache" :
                effectivelyComplete ? "Fill remaining (\(uncachedCount))" :
                                      "Cache all release details"
            ) {
                if allCached {
                    showRefreshAlert = true
                } else {
                    cacheCoordinator.start()
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(isRunning)
            .padding(.top, 10)
        }
    }

    // MARK: - Recordings card

    private var recordingsCard: some View {
        let fetchedCount = stats.recordingsFetched
        let skippedCount = stats.recordingsSkipped
        let failedCount  = stats.recordingsFailed
        let trackCount   = stats.trackCount
        let totalCached  = stats.decodedTrackCount
        let isRunning: Bool = {
            switch recordingsCoordinator.phase {
            case .scanning, .paused: return true
            default: return false
            }
        }()
        let canFetch = recordingsCoordinator.unscannedWithMBIDCount > 0

        return VStack(alignment: .leading, spacing: 0) {
            sectionHeader(title: "Recording MBIDs")

            if trackCount > 0 {
                VStack(alignment: .leading, spacing: 8) {
                    progressRow(count: trackCount, total: totalCached, noun: "tracks have recording MBIDs")

                    VStack(spacing: 4) {
                        recordingStateRow(icon: "checkmark.circle.fill",  iconColor: .green,    label: "Fetched",         count: fetchedCount)
                        recordingStateRow(icon: "circle.dotted",           iconColor: .secondary, label: "Skipped (no MBID)", count: skippedCount)
                        recordingStateRow(icon: "xmark.circle.fill",       iconColor: .red,      label: "Failed",          count: failedCount)
                    }
                    .padding(.top, 4)
                }
            } else {
                Text("No recording MBIDs yet. Use \"Fetch tracks\" to pull track-level data from MusicBrainz for all matched releases (~7–8 min).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button(isRunning ? "Fetching…" : (canFetch ? "Fetch tracks for unscanned" : "All up to date")) {
                recordingsCoordinator.start()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(isRunning || !canFetch)
            .padding(.top, 10)
        }
    }

    private func recordingStateRow(icon: String, iconColor: Color, label: String, count: Int) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(count > 0 ? iconColor : Color.secondary.opacity(0.3))
                .font(.body)
                .frame(width: 16)
            Text(label)
                .font(.body)
                .foregroundStyle(count > 0 ? .primary : .secondary)
            Spacer()
            Text(count.formatted())
                .font(.body.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Audio Features card

    private var audioFeaturesCard: some View {
        let withData    = stats.featuresWithBPM
        let noData      = stats.featureCount - stats.featuresWithBPM
        let withBPM     = stats.featuresWithBPM
        let withKey     = stats.featuresWithKey
        let withBoth    = stats.featuresWithBoth
        let totalMBIDs  = stats.distinctRecordingMBIDCount
        let notQueried  = max(0, totalMBIDs - stats.featureCount)
        let isRunning: Bool = {
            switch audioFeaturesCoordinator.phase {
            case .scanning, .paused: return true
            default: return false
            }
        }()
        let canScan = audioFeaturesCoordinator.unqueriedCount > 0

        return VStack(alignment: .leading, spacing: 0) {
            sectionHeader(title: "Web BPM/Key (AcousticBrainz) — Historical")
            Text("No longer fetched automatically — local analysis above is now the primary BPM/key source. Existing data stays here; you can still scan manually.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.bottom, 6)

            if stats.featureCount == 0 {
                Text("No audio features on file. Use \"Scan unqueried tracks\" below to query AcousticBrainz manually.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    progressRow(count: withData, total: totalMBIDs, noun: "tracks have BPM and key data")

                    VStack(spacing: 4) {
                        audioFeatureRow(icon: "checkmark.circle.fill", iconColor: .green,       label: "BPM available",   count: withBPM)
                        audioFeatureRow(icon: "checkmark.circle.fill", iconColor: .green,       label: "Key available",   count: withKey)
                        audioFeatureRow(icon: "checkmark.circle.fill", iconColor: .accentColor, label: "Both BPM + key", count: withBoth)
                        audioFeatureRow(icon: "circle",                iconColor: .secondary,   label: "Queried, no data", count: noData)
                        audioFeatureRow(icon: "circle",                iconColor: .secondary,   label: "Not yet queried",  count: notQueried)
                    }
                    .padding(.top, 4)

                    if withBPM >= 50 {
                        bpmRangeRow
                    }
                    if withKey >= 50 {
                        topCamelotRow
                    }
                }
            }

            Button(isRunning ? "Scanning…" : (canScan ? "Scan unqueried tracks" : "All queried")) {
                audioFeaturesCoordinator.start()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(isRunning || !canScan)
            .padding(.top, 10)
        }
    }

    // MARK: - Local Files card

    private var localFilesCard: some View {
        let total      = fileMatchCoordinator.totalTracksWithRecordingMBID
        let confident  = fileMatchCoordinator.confidentFileCount
        let review     = fileMatchCoordinator.reviewFileCount
        let noMatch    = fileMatchCoordinator.noMatchFileCount
        let isRunning: Bool = {
            switch fileMatchCoordinator.phase {
            case .indexing, .matching, .paused: return true
            default: return false
            }
        }()

        return VStack(alignment: .leading, spacing: 0) {
            sectionHeader(title: "Linked Files")

            if stats.totalLocalFileCount == 0 && confident == 0 {
                Text("No files matched yet. Run 'Match all tracks' to link local audio files to collection tracks.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    progressRow(count: confident, total: total, noun: "tracks confidently matched to files")

                    VStack(spacing: 4) {
                        recordingStateRow(icon: "checkmark.circle.fill",    iconColor: .green,    label: "Confident",     count: confident)
                        recordingStateRow(icon: "questionmark.circle.fill", iconColor: .orange,   label: "Needs review",  count: review)
                        recordingStateRow(icon: "circle",                   iconColor: .secondary, label: "No match",     count: noMatch)
                        recordingStateRow(icon: "waveform",                 iconColor: .secondary, label: "Files indexed", count: stats.totalLocalFileCount)
                    }
                    .padding(.top, 4)
                }
            }

            if fileMatchCoordinator.shouldShowPanel {
                FileMatchPanelView(coordinator: fileMatchCoordinator)
                    .padding(.top, 8)
            }

            HStack(spacing: 8) {
                Button(isRunning ? "Matching…" : "Match tracks to files") {
                    fileMatchCoordinator.startFullScan()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(isRunning)
            }
            .padding(.top, 10)
        }
    }

    // MARK: - Local Audio Analysis card

    private var localAnalysisCard: some View {
        let confident = localAnalysisCoordinator.confidentCount
        // Only count features whose owning track is still confident-matched — a track can
        // fall out of "confident" (re-match, manual unlink) after being analyzed, leaving a
        // stale LocalAudioFeaturesEntity row that no longer belongs in this ratio.
        let settledAnalyzed = stats.settledLocalAnalyzedCount
        let remaining = max(0, confident - settledAnalyzed)
        let isRunning = localAnalysisCoordinator.phase == .analyzing
                     || localAnalysisCoordinator.phase == .paused
        let isRunningTracks = isRunning && localAnalysisCoordinator.currentMode == .tracks
        // While a track-mode analysis is running, read the coordinator's published counters
        // instead of the @Query — they're updated per-track in runAnalysis() regardless of
        // save cadence, so the header stays live even once flushResults() batches its saves.
        // (Also correct for a limited "Test (first 10)" run, where totalCount != confident.)
        let analyzed      = isRunningTracks ? localAnalysisCoordinator.analyzedCount : settledAnalyzed
        let progressTotal = isRunningTracks ? localAnalysisCoordinator.totalCount : confident
        let fileTotal      = localAnalysisCoordinator.inScopeFileCount
        let fileUnanalyzed = localAnalysisCoordinator.unanalyzedFileCount
        let fileAnalyzed   = max(0, fileTotal - fileUnanalyzed)

        return VStack(alignment: .leading, spacing: 0) {
            sectionHeader(title: "Detect BPM/Key — linked tracks")

            if confident == 0 {
                Text("No confident-matched tracks yet. Run file matching first.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    progressRow(count: analyzed, total: progressTotal, noun: "confident tracks analyzed locally")

                    if settledAnalyzed > 0 {
                        localBpmRangeRow
                        localTopCamelotRow
                    }
                }
            }

            if localAnalysisCoordinator.shouldShowPanel {
                LocalAnalysisPanelView(coordinator: localAnalysisCoordinator)
                    .padding(.top, 8)
            }

            HStack(spacing: 8) {
                Button(isRunning ? "Analyzing…" : (remaining > 0 ? "Analyze \(remaining) remaining" : "All analyzed")) {
                    localAnalysisCoordinator.startAnalysis()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(isRunning || remaining == 0)

                Button("Test (first 10)") {
                    localAnalysisCoordinator.startTestBatch()
                }
                .controlSize(.small)
                .disabled(isRunning || confident == 0)

                // Essentia availability check
                essentiaTestButton
            }
            .padding(.top, 10)

            Divider().padding(.vertical, 8)

            VStack(alignment: .leading, spacing: 6) {
                Text("Detect BPM/Key — all files")
                    .font(.title3.weight(.semibold))

                if fileTotal > 0 {
                    progressRow(count: fileAnalyzed, total: fileTotal, noun: "files analyzed")
                } else {
                    Text("Run file matching first — scope is computed from collection artist folders.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 8) {
                Button(isRunning ? "Analyzing…" : (fileUnanalyzed > 0 ? "Analyze collection files (\(fileUnanalyzed))" : "Files up to date")) {
                    localAnalysisCoordinator.startFileAnalysis()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(isRunning || fileUnanalyzed == 0)

                Button("Test (first 10)") {
                    localAnalysisCoordinator.startFileAnalysis(limit: 10)
                }
                .controlSize(.small)
                .disabled(isRunning || fileTotal == 0)
            }
            .padding(.top, 6)
        }
    }

    @ViewBuilder
    private var essentiaTestButton: some View {
        switch localAnalysisCoordinator.essentiaStatus {
        case .unknown:
            Button("Test Essentia") { localAnalysisCoordinator.testEssentia() }
                .controlSize(.small)
        case .testing:
            ProgressView().scaleEffect(0.7)
        case .installed(let ver):
            Label(ver, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green).font(.caption)
        case .notInstalled:
            Label("Essentia not installed — see Settings", systemImage: "xmark.circle.fill")
                .foregroundStyle(.orange).font(.caption)
        case .installing:
            HStack(spacing: 4) {
                ProgressView().scaleEffect(0.7)
                Text("Installing…").font(.caption).foregroundStyle(.secondary)
            }
        case .installFailed(let msg):
            Label("Install failed: \(msg)", systemImage: "xmark.circle.fill")
                .foregroundStyle(.red).font(.caption).lineLimit(2)
        case .testFailed(let msg):
            Label("Test failed: \(msg)", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red).font(.caption).lineLimit(2)
        }
    }

    @ViewBuilder
    private var localBpmRangeRow: some View {
        let bpms = stats.localBPMsSorted
        if let minBPM = bpms.first, let maxBPM = bpms.last {
            let median = bpms[bpms.count / 2]
            Text("BPM range: \(Int(minBPM))–\(Int(maxBPM))  (median \(Int(median)))")
                .font(.body)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var localTopCamelotRow: some View {
        let counts = stats.localCamelotCounts
        if !counts.isEmpty {
            let top3 = counts.sorted { $0.value > $1.value }.prefix(3)
            let parts = top3.map { code, count -> String in
                let desc = CamelotConverter.descriptions[code] ?? ""
                return "\(code) (\(desc)): \(count)"
            }.joined(separator: "  ·  ")
            Text("Most common keys:  \(parts)")
                .font(.body)
                .foregroundStyle(.secondary)
        }
    }

    private func audioFeatureRow(icon: String, iconColor: Color, label: String, count: Int) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(count > 0 ? iconColor : Color.secondary.opacity(0.3))
                .font(.body)
                .frame(width: 16)
            Text(label)
                .font(.body)
                .foregroundStyle(count > 0 ? .primary : .secondary)
            Spacer()
            Text(count.formatted())
                .font(.body.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var bpmRangeRow: some View {
        let bpms = stats.featureBPMsSorted
        if let minBPM = bpms.first, let maxBPM = bpms.last {
            let median = bpms[bpms.count / 2]
            Text("BPM range: \(Int(minBPM))–\(Int(maxBPM))  (median \(Int(median)))")
                .font(.body)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var topCamelotRow: some View {
        let counts = stats.featureCamelotCounts
        if !counts.isEmpty {
            let top3 = counts.sorted { $0.value > $1.value }.prefix(3)
            let parts = top3.map { code, count -> String in
                let desc = CamelotConverter.descriptions[code] ?? ""
                return "\(code) (\(desc)): \(count)"
            }.joined(separator: "  ·  ")
            Text("Most common keys:  \(parts)")
                .font(.body)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Computed stats

    private var yearRangeLabel: String {
        guard let minY = stats.validYears.min(), let maxY = stats.validYears.max() else { return "—" }
        return "\(minY)–\(maxY)"
    }

    private var medianAge: Int {
        let sorted = stats.validYears.sorted()
        guard !sorted.isEmpty else { return 0 }
        let median = sorted[sorted.count / 2]
        return Calendar.current.component(.year, from: Date()) - median
    }

    // MARK: - Track stats (from decoded cache)

    private var estimatedTotalTracks: Int? {
        guard stats.decodedDetailCount > 0, stats.decodedDetailCount < stats.releaseCount else { return nil }
        return (stats.decodedTrackCount / stats.decodedDetailCount) * stats.releaseCount
    }

    private var cachePercent: Int {
        guard stats.releaseCount > 0 else { return 0 }
        return stats.decodedDetailCount * 100 / stats.releaseCount
    }

    private var cachedDurationLabel: String {
        let h = stats.decodedDurationSeconds / 3600
        let m = (stats.decodedDurationSeconds % 3600) / 60
        if h > 0 { return "\(h) h \(m) min" }
        let s = stats.decodedDurationSeconds % 60
        return "\(m) min \(s) sec"
    }

    // MARK: - Cue Point Detection card

    private var cueDetectionCard: some View {
        let withCues = stats.localFilesWithCuesCount
        let analyzed = stats.analyzedLocalFileCount
        let isDetecting = cueCoordinator.phase == .detecting || cueCoordinator.phase == .paused

        return VStack(alignment: .leading, spacing: 0) {
            sectionHeader(title: "Cue Point Detection")

            if analyzed == 0 {
                Text("No analyzed files yet — run local audio analysis first.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    progressRow(count: withCues, total: analyzed, noun: "analyzed files have cue points")
                }
            }

            if cueCoordinator.phase == .detecting {
                HStack(spacing: 6) {
                    ProgressView().scaleEffect(0.75)
                    Text("\(cueCoordinator.processedCount) / \(cueCoordinator.totalCount) — \(cueCoordinator.currentFileLabel)")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .padding(.top, 4)
            }

            HStack(spacing: 8) {
                Button(isDetecting ? "Detecting…" : "Scan all confident tracks") {
                    cueCoordinator.startDetection(scope: .matched)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(isDetecting)

                Button("Scan all tracks") {
                    cueCoordinator.startDetection(scope: .all)
                }
                .controlSize(.small)
                .disabled(isDetecting)
            }
            .padding(.top, 10)
        }
    }
}
