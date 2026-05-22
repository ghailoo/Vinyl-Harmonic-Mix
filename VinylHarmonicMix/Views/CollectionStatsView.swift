import SwiftUI
import SwiftData

struct CollectionStatsView: View {
    @Environment(DetailCacheCoordinator.self) private var cacheCoordinator
    @Environment(RecordingsScanCoordinator.self) private var recordingsCoordinator
    @Environment(AudioFeaturesScanCoordinator.self) private var audioFeaturesCoordinator
    @Environment(FileMatchCoordinator.self) private var fileMatchCoordinator
    @Environment(LocalAnalysisCoordinator.self) private var localAnalysisCoordinator
    @Query private var entities: [CollectionItemEntity]
    @Query private var detailEntities: [ReleaseDetailEntity]
    @Query private var trackEntities: [TrackEntity]
    @Query private var featureEntities: [RecordingFeaturesEntity]
    @Query private var localFeatureEntities: [LocalAudioFeaturesEntity]
    @Query private var localFileEntities: [LocalFileEntity]

    @State private var cachedDetails: [ReleaseDetail] = []
    @State private var showRefreshAlert = false

    var body: some View {
        Group {
            if entities.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "tray")
                        .font(.system(size: 48))
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
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            Text("Stats")
                                .font(.system(size: 28, weight: .bold))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.bottom, 4)

                            heroCard

                            if !formatCounts.isEmpty  { formatCard }
                            if !genreCounts.isEmpty   { genreCard }
                            if !decadeCounts.isEmpty  { decadeCard }
                            if !labelCounts.isEmpty   { labelsCard }
                            if !artistCounts.isEmpty  { artistsCard }
                            tracksCard
                            recordingsCard
                            audioFeaturesCard
                            localFilesCard
                            localAnalysisCard
                        }
                        .padding(.horizontal, 24)
                        .padding(.vertical, 20)
                    }
                }
                .animation(.easeInOut(duration: 0.25), value: cacheCoordinator.shouldShowPanel)
            }
        }
        .navigationTitle("Stats")
        .task(id: detailEntities.count) {
            cachedDetails = detailEntities.compactMap {
                try? JSONDecoder().decode(ReleaseDetail.self, from: $0.jsonData)
            }
        }
        .alert("Refresh all cached details?", isPresented: $showRefreshAlert) {
            Button("Refresh (~15 min)", role: .destructive) { cacheCoordinator.startRefresh() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All \(entities.count.formatted()) releases are already cached. Re-fetching will overwrite existing data and take approximately 15 minutes.")
        }
    }

    // MARK: - Card wrapper

    private func sectionCard<Content: View>(accent: Bool = false, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .padding(20)
        .background(
            accent ? Color.accentColor.opacity(0.06) : Color.secondary.opacity(0.06),
            in: RoundedRectangle(cornerRadius: 12)
        )
    }

    // MARK: - Section header

    @ViewBuilder
    private func sectionHeader(title: String, total: Int? = nil, shown: Int? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 17, weight: .semibold))
            if let total, let shown, shown < total {
                Text("\(shown) of \(total) unique")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.bottom, 12)
    }

    // MARK: - Hero card

    private var heroCard: some View {
        sectionCard {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 16) {
                statTile(value: entities.count.formatted(), label: "releases", accent: false)
                statTile(value: matchedCount.formatted(), label: "matched", accent: true)
                statTile(value: yearRangeLabel, label: "year range", accent: false)
                statTile(value: medianAge > 0 ? "\(medianAge) years" : "—", label: "median age", accent: false)
            }
        }
    }

    private func statTile(value: String, label: String, accent: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.system(size: 32, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(accent ? Color.accentColor : Color.primary)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Format card

    private var formatCard: some View {
        sectionCard {
            sectionHeader(title: "Releases by format")
            VStack(spacing: 6) {
                ForEach(Array(formatCounts.enumerated()), id: \.offset) { _, item in
                    HStack(spacing: 8) {
                        Image(systemName: formatIcon(for: item.label))
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                            .frame(width: 18, alignment: .center)
                        Text(item.label)
                            .font(.system(size: 14))
                        Spacer()
                        Text(item.count.formatted())
                            .font(.system(size: 14).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 50, alignment: .trailing)
                    }
                }
            }
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
        let all = genreCounts
        let shown = Array(all.prefix(8))
        return sectionCard {
            sectionHeader(title: "Releases by genre", total: all.count, shown: shown.count)
            VStack(spacing: 6) {
                ForEach(Array(shown.enumerated()), id: \.offset) { _, item in
                    HStack {
                        Text(item.label).font(.system(size: 14))
                        Spacer()
                        Text(item.count.formatted())
                            .font(.system(size: 14).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 50, alignment: .trailing)
                    }
                }
            }
        }
    }

    // MARK: - Decade card

    private var decadeCard: some View {
        let items = decadeCounts
        let maxCount = items.map(\.count).max() ?? 1
        return sectionCard {
            sectionHeader(title: "Releases by decade")
            VStack(spacing: 10) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    decadeRow(decade: item.label, count: item.count, maxCount: maxCount)
                }
            }
        }
    }

    private func decadeRow(decade: String, count: Int, maxCount: Int) -> some View {
        HStack(spacing: 12) {
            Text(decade)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 60, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.secondary.opacity(0.15))
                        .frame(height: 8)
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(
                            width: maxCount > 0
                                ? geo.size.width * CGFloat(count) / CGFloat(maxCount)
                                : 0,
                            height: 8
                        )
                }
            }
            .frame(height: 8)
            Text(count.formatted())
                .font(.system(size: 13).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 50, alignment: .trailing)
        }
    }

    // MARK: - Labels card

    private var labelsCard: some View {
        let items = labelCounts
        return sectionCard {
            sectionHeader(title: "Top labels by releases")
            VStack(spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(spacing: 8) {
                        Text("\(index + 1)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.tertiary)
                            .frame(width: 20, alignment: .trailing)
                        Text(item.label).font(.system(size: 14))
                        Spacer()
                        Text(item.count.formatted())
                            .font(.system(size: 14).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 50, alignment: .trailing)
                    }
                }
            }
        }
    }

    // MARK: - Artists card

    private var artistsCard: some View {
        let items = artistCounts
        return sectionCard {
            sectionHeader(title: "Top artists by releases")
            VStack(spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(spacing: 8) {
                        Text("\(index + 1)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.tertiary)
                            .frame(width: 20, alignment: .trailing)
                        Text(item.label).font(.system(size: 14))
                        Spacer()
                        Text(item.count.formatted())
                            .font(.system(size: 14).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 50, alignment: .trailing)
                    }
                }
            }
        }
    }

    // MARK: - Tracks card

    private var cacheIsEffectivelyComplete: Bool {
        guard entities.count > 0 else { return false }
        return cachedDetailCount >= Int(Double(entities.count) * 0.95)
    }

    private var tracksCard: some View {
        let cachedCount = detailEntities.count
        let totalCount = entities.count
        let allCached = cachedCount >= totalCount && totalCount > 0
        let effectivelyComplete = cacheIsEffectivelyComplete
        let uncachedCount = max(0, totalCount - cachedCount)
        let isRunning: Bool = {
            switch cacheCoordinator.phase {
            case .scanning, .paused: return true
            default: return false
            }
        }()

        return sectionCard(accent: !effectivelyComplete && !allCached) {
            HStack(spacing: 6) {
                Text("Tracks & duration")
                    .font(.system(size: 17, weight: .semibold))
                if cachedDetailCount > 0 && !effectivelyComplete {
                    HStack(spacing: 4) {
                        Image(systemName: "info.circle").font(.caption)
                        Text("Partial data").font(.caption)
                    }
                    .foregroundStyle(.tertiary)
                }
                Spacer()
            }
            .padding(.bottom, 12)

            if cachedDetailCount == 0 {
                Text("No detail data yet. Cache all releases to see tracklists, duration, and credits (~15 min).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    if allCached {
                        Text("\(cachedTrackCount.formatted()) tracks across all \(totalCount.formatted()) releases")
                            .font(.system(size: 14))
                    } else {
                        Text("\(cachedTrackCount.formatted()) tracks across \(cachedDetailCount.formatted()) of \(totalCount.formatted()) releases (\(cachePercent)%)")
                            .font(.system(size: 14))
                        if !effectivelyComplete, let est = estimatedTotalTracks {
                            Text("Estimated total: \(est.formatted()) tracks (extrapolated)")
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text("Recorded duration: \(cachedDurationLabel) (from cached data)")
                        .font(.system(size: 13))
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
        let fetchedCount = entities.filter { $0.recordingsScanState == "fetched" }.count
        let skippedCount = entities.filter { $0.recordingsScanState == "skipped" }.count
        let failedCount  = entities.filter { $0.recordingsScanState == "failed"  }.count
        let trackCount   = trackEntities.count
        let totalCached  = cachedDetails.reduce(0) { $0 + $1.tracklist.count }
        let trackPercent = totalCached > 0 ? min(100, trackCount * 100 / max(totalCached, 1)) : 0
        let isRunning: Bool = {
            switch recordingsCoordinator.phase {
            case .scanning, .paused: return true
            default: return false
            }
        }()
        let canFetch = recordingsCoordinator.unscannedWithMBIDCount > 0

        return sectionCard {
            sectionHeader(title: "Recording MBIDs")

            if trackCount > 0 {
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(trackCount.formatted()) tracks have recording MBIDs (\(trackPercent)% of cached tracks)")
                        .font(.system(size: 14))

                    // Progress bar
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.secondary.opacity(0.15)).frame(height: 8)
                            Capsule()
                                .fill(Color.accentColor)
                                .frame(
                                    width: totalCached > 0 ? geo.size.width * CGFloat(trackCount) / CGFloat(max(totalCached, 1)) : 0,
                                    height: 8
                                )
                        }
                    }
                    .frame(height: 8)

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
                .font(.system(size: 13))
                .frame(width: 16)
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(count > 0 ? .primary : .secondary)
            Spacer()
            Text(count.formatted())
                .font(.system(size: 13).monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Audio Features card

    private var audioFeaturesCard: some View {
        let withData    = featureEntities.filter { $0.bpm != nil }.count
        let noData      = featureEntities.filter { $0.bpm == nil }.count
        let withBPM     = featureEntities.filter { $0.bpm != nil }.count
        let withKey     = featureEntities.filter { $0.keyNote != nil }.count
        let withBoth    = featureEntities.filter { $0.bpm != nil && $0.keyNote != nil }.count
        let totalMBIDs  = Set(trackEntities.map(\.recordingMBID).filter { !$0.isEmpty }).count
        let notQueried  = max(0, totalMBIDs - featureEntities.count)
        let pct         = totalMBIDs > 0 ? min(100, withData * 100 / max(totalMBIDs, 1)) : 0
        let isRunning: Bool = {
            switch audioFeaturesCoordinator.phase {
            case .scanning, .paused: return true
            default: return false
            }
        }()
        let canScan = audioFeaturesCoordinator.unqueriedCount > 0

        return sectionCard {
            sectionHeader(title: "Audio Features")

            if featureEntities.isEmpty {
                Text("No audio features yet. Use \"Scan audio\" to query AcousticBrainz for BPM and key data (~3 min).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(withData.formatted()) tracks have BPM and key data (\(pct)% of recording MBIDs)")
                        .font(.system(size: 14))

                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.secondary.opacity(0.15)).frame(height: 8)
                            Capsule()
                                .fill(Color.accentColor)
                                .frame(
                                    width: totalMBIDs > 0
                                        ? geo.size.width * CGFloat(withData) / CGFloat(max(totalMBIDs, 1))
                                        : 0,
                                    height: 8
                                )
                        }
                    }
                    .frame(height: 8)

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
        let pct        = total > 0 ? min(100, confident * 100 / total) : 0
        let isRunning: Bool = {
            switch fileMatchCoordinator.phase {
            case .indexing, .matching, .paused: return true
            default: return false
            }
        }()

        return sectionCard {
            sectionHeader(title: "Local Files")

            if localFileEntities.isEmpty && confident == 0 {
                Text("No files matched yet. Run 'Match all tracks' to link local audio files to collection tracks.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(confident.formatted()) confident · \(review.formatted()) to review · \(noMatch.formatted()) no match  (of \(total.formatted()))")
                        .font(.system(size: 14))

                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.secondary.opacity(0.15)).frame(height: 8)
                            Capsule()
                                .fill(Color.green)
                                .frame(
                                    width: total > 0
                                        ? geo.size.width * CGFloat(confident) / CGFloat(max(total, 1))
                                        : 0,
                                    height: 8
                                )
                        }
                    }
                    .frame(height: 8)

                    VStack(spacing: 4) {
                        recordingStateRow(icon: "checkmark.circle.fill",    iconColor: .green,    label: "Confident",     count: confident)
                        recordingStateRow(icon: "questionmark.circle.fill", iconColor: .orange,   label: "Needs review",  count: review)
                        recordingStateRow(icon: "circle",                   iconColor: .secondary, label: "No match",     count: noMatch)
                        recordingStateRow(icon: "waveform",                 iconColor: .secondary, label: "Files indexed", count: localFileEntities.count)
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
        let analyzed  = localFeatureEntities.count
        let remaining = max(0, confident - analyzed)
        let pct = confident > 0 ? min(100, analyzed * 100 / max(confident, 1)) : 0
        let isRunning = localAnalysisCoordinator.phase == .analyzing
                     || localAnalysisCoordinator.phase == .paused

        return sectionCard {
            sectionHeader(title: "Local Audio Analysis")

            if confident == 0 {
                Text("No confident-matched tracks yet. Run file matching first.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(analyzed.formatted()) of \(confident.formatted()) confident tracks analyzed locally (\(pct)%)")
                        .font(.system(size: 14))

                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.secondary.opacity(0.15)).frame(height: 8)
                            Capsule()
                                .fill(Color.purple)
                                .frame(
                                    width: confident > 0
                                        ? geo.size.width * CGFloat(analyzed) / CGFloat(max(confident, 1))
                                        : 0,
                                    height: 8
                                )
                        }
                    }
                    .frame(height: 8)

                    if analyzed > 0 {
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
        let bpms = localFeatureEntities.map(\.bpm).filter { $0 > 0 }.sorted()
        if let minBPM = bpms.first, let maxBPM = bpms.last {
            let median = bpms[bpms.count / 2]
            Text("BPM range: \(Int(minBPM))–\(Int(maxBPM))  (median \(Int(median)))")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var localTopCamelotRow: some View {
        let codes = localFeatureEntities.map(\.camelot).filter { !$0.isEmpty }
        if !codes.isEmpty {
            let counts = Dictionary(codes.map { ($0, 1) }, uniquingKeysWith: +)
            let top3 = counts.sorted { $0.value > $1.value }.prefix(3)
            let parts = top3.map { code, count -> String in
                let desc = CamelotConverter.descriptions[code] ?? ""
                return "\(code) (\(desc)): \(count)"
            }.joined(separator: "  ·  ")
            Text("Most common keys:  \(parts)")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
    }

    private func audioFeatureRow(icon: String, iconColor: Color, label: String, count: Int) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(count > 0 ? iconColor : Color.secondary.opacity(0.3))
                .font(.system(size: 13))
                .frame(width: 16)
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(count > 0 ? .primary : .secondary)
            Spacer()
            Text(count.formatted())
                .font(.system(size: 13).monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var bpmRangeRow: some View {
        let bpms = featureEntities.compactMap(\.bpm).sorted()
        if let minBPM = bpms.first, let maxBPM = bpms.last {
            let median = bpms[bpms.count / 2]
            Text("BPM range: \(Int(minBPM))–\(Int(maxBPM))  (median \(Int(median)))")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var topCamelotRow: some View {
        let codes = featureEntities.compactMap(\.camelotCode)
        if !codes.isEmpty {
            let counts = Dictionary(codes.map { ($0, 1) }, uniquingKeysWith: +)
            let top3 = counts.sorted { $0.value > $1.value }.prefix(3)
            let parts = top3.map { code, count -> String in
                let desc = CamelotConverter.descriptions[code] ?? ""
                return "\(code) (\(desc)): \(count)"
            }.joined(separator: "  ·  ")
            Text("Most common keys:  \(parts)")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Computed stats

    private var matchedCount: Int {
        entities.filter {
            $0.mbidScanState == "matched" || $0.mbidScanState == "matchedViaSearch" || $0.mbidScanState == "matchedManually"
        }.count
    }

    private var validYears: [Int] {
        entities.compactMap { $0.basicInformation?.year }.filter { $0 > 0 }
    }

    private var yearRangeLabel: String {
        guard let minY = validYears.min(), let maxY = validYears.max() else { return "—" }
        return "\(minY)–\(maxY)"
    }

    private var medianAge: Int {
        let sorted = validYears.sorted()
        guard !sorted.isEmpty else { return 0 }
        let median = sorted[sorted.count / 2]
        return Calendar.current.component(.year, from: Date()) - median
    }

    private var formatCounts: [(label: String, count: Int)] {
        var counts: [String: Int] = [:]
        for entity in entities {
            let name = entity.basicInformation?.formats.first?.name ?? "Unknown"
            counts[name, default: 0] += 1
        }
        return counts.sorted { $0.value > $1.value }.map { (label: $0.key, count: $0.value) }
    }

    private var genreCounts: [(label: String, count: Int)] {
        var counts: [String: Int] = [:]
        for entity in entities {
            for genre in entity.basicInformation?.genres ?? [] {
                counts[genre, default: 0] += 1
            }
        }
        return counts.sorted { $0.value > $1.value }.map { (label: $0.key, count: $0.value) }
    }

    private var decadeCounts: [(label: String, count: Int)] {
        var counts: [Int: Int] = [:]
        for entity in entities {
            guard let year = entity.basicInformation?.year, year > 0 else { continue }
            let decade = (year / 10) * 10
            counts[decade, default: 0] += 1
        }
        return counts.sorted { $0.key < $1.key }.map { (label: "\($0.key)s", count: $0.value) }
    }

    private var labelCounts: [(label: String, count: Int)] {
        var counts: [String: Int] = [:]
        for entity in entities {
            guard let name = entity.basicInformation?.labels.first?.name else { continue }
            counts[name, default: 0] += 1
        }
        return counts.sorted { $0.value > $1.value }.prefix(10).map { (label: $0.key, count: $0.value) }
    }

    private var artistCounts: [(label: String, count: Int)] {
        let excluded: Set<String> = ["various", "various artists", "unknown artist"]
        var counts: [String: Int] = [:]
        for entity in entities {
            guard let name = entity.basicInformation?.artists.first?.name else { continue }
            guard !excluded.contains(name.lowercased()) else { continue }
            counts[name, default: 0] += 1
        }
        return counts.sorted { $0.value > $1.value }.prefix(10).map { (label: $0.key, count: $0.value) }
    }

    // MARK: - Track stats (from decoded cache)

    private var cachedDetailCount: Int { cachedDetails.count }

    private var cachedTrackCount: Int {
        cachedDetails.reduce(0) { $0 + $1.tracklist.count }
    }

    private var cachedDurationSeconds: Int {
        cachedDetails.flatMap(\.tracklist).reduce(0) { total, track in
            total + parseDuration(track.duration)
        }
    }

    private var estimatedTotalTracks: Int? {
        guard cachedDetailCount > 0, cachedDetailCount < entities.count else { return nil }
        return (cachedTrackCount / cachedDetailCount) * entities.count
    }

    private var cachePercent: Int {
        guard entities.count > 0 else { return 0 }
        return cachedDetailCount * 100 / entities.count
    }

    private var cachedDurationLabel: String {
        let h = cachedDurationSeconds / 3600
        let m = (cachedDurationSeconds % 3600) / 60
        if h > 0 { return "\(h) h \(m) min" }
        let s = cachedDurationSeconds % 60
        return "\(m) min \(s) sec"
    }

    private func parseDuration(_ s: String) -> Int {
        guard !s.isEmpty else { return 0 }
        let parts = s.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return 0 }
        return parts[0] * 60 + parts[1]
    }
}
