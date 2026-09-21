import SwiftUI
import SwiftData
#if os(macOS)
import AppKit
#endif

struct FileMatchesView: View {
    @Environment(FileMatchCoordinator.self) private var coordinator

    @Query(filter: #Predicate<TrackEntity> { $0.fileMatchState == "confident" },
           sort: \TrackEntity.artistCredit)
    private var confidentTracks: [TrackEntity]

    @Query(filter: #Predicate<TrackEntity> { $0.fileMatchState == "review" },
           sort: \TrackEntity.artistCredit)
    private var reviewTracks: [TrackEntity]

    @Query(filter: #Predicate<TrackEntity> { $0.fileMatchState == "noMatch" },
           sort: \TrackEntity.artistCredit)
    private var noMatchTracks: [TrackEntity]

    private enum Segment: Hashable { case confident, review, noMatch }
    @State private var segment: Segment = .review
    @State private var searchQuery: String = ""

    // MARK: - Filtered lists (in-memory, case-insensitive, live)

    private func filtered(_ tracks: [TrackEntity]) -> [TrackEntity] {
        guard !searchQuery.isEmpty else { return tracks }
        let q = searchQuery.lowercased()
        return tracks.filter { track in
            track.artistCredit.lowercased().contains(q) ||
            track.title.lowercased().contains(q) ||
            track.primaryLocalFilePath.map {
                URL(fileURLWithPath: $0).lastPathComponent.lowercased().contains(q)
            } ?? false ||
            (coordinator.reviewCandidates[track.trackMBID]?.contains(where: {
                URL(fileURLWithPath: $0.filePath).lastPathComponent.lowercased().contains(q)
            }) ?? false)
        }
    }

    private var filteredConfident: [TrackEntity] { filtered(confidentTracks) }
    private var filteredReview: [TrackEntity] { filtered(reviewTracks) }
    private var filteredNoMatch: [TrackEntity] { filtered(noMatchTracks) }

    private var segmentHeading: String {
        switch segment {
        case .confident: return "Confident matches · \(filteredConfident.count)"
        case .review:    return "Needs review · \(filteredReview.count)"
        case .noMatch:   return "No match found · \(filteredNoMatch.count)"
        }
    }

    // MARK: - Search field

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Filter by artist, title, or filename…", text: $searchQuery)
                .textFieldStyle(.plain)
            if !searchQuery.isEmpty {
                Button {
                    searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    var body: some View {
        PerfLog.begin("FileMatchesView.body")
        defer { PerfLog.end("FileMatchesView.body") }
        let _ = PerfLog.measure("FileMatchesView.query.confidentTracks") { confidentTracks.count }
        let _ = PerfLog.measure("FileMatchesView.query.reviewTracks") { reviewTracks.count }
        let _ = PerfLog.measure("FileMatchesView.query.noMatchTracks") { noMatchTracks.count }
        return Group {
            if confidentTracks.isEmpty && reviewTracks.isEmpty && noMatchTracks.isEmpty {
                emptyState
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    searchField

                    Picker("Section", selection: $segment) {
                        Text("Confident (\(filteredConfident.count))").tag(Segment.confident)
                        Text("Needs Review (\(filteredReview.count))").tag(Segment.review)
                        Text("No Match (\(filteredNoMatch.count))").tag(Segment.noMatch)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    // Middle typographic tier between the window's navigationTitle and the
                    // table's small row text, so that jump isn't so abrupt.
                    Text(segmentHeading)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.secondary)

                    Group {
                        switch segment {
                        case .confident:
                            ConfidentMasterDetailView(tracks: filteredConfident, coordinator: coordinator)
                        case .review:
                            ReviewMasterDetailView(tracks: filteredReview, coordinator: coordinator)
                        case .noMatch:
                            NoMatchMasterDetailView(tracks: filteredNoMatch, coordinator: coordinator)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
            }
        }
        .navigationTitle("File Matches")
        .onAppear { coordinator.hydrateReviewCandidatesIfNeeded() }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform.and.magnifyingglass")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("No matches yet.")
                .foregroundStyle(.secondary)
            Text("Run \"Match all tracks\" from Stats or Settings.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Library root URL helper

private func libraryRootURL() -> URL? {
    guard let path = UserDefaults.standard.string(forKey: LocalLibraryService.displayPathKey) else { return nil }
    return URL(fileURLWithPath: path)
}

// MARK: - Mix check (Discogs version/mix vs. candidate's version/mix)

private enum MixCheck: CaseIterable {
    case same, different, unknown

    var symbol: String {
        switch self {
        case .same:      return "✓"
        case .different:  return "≠"
        case .unknown:    return "—"
        }
    }
    var label: String {
        switch self {
        case .same:      return "same mix"
        case .different:  return "different mix"
        case .unknown:    return "no mix info"
        }
    }
    var tint: Color {
        switch self {
        case .same:      return .green
        case .different:  return .orange
        case .unknown:    return .secondary
        }
    }
}

/// Reuses FuzzyMatch's existing version extraction/comparison — no new parser.
/// Nil on either side (no parenthetical on the Discogs title, or the file has none) means
/// there isn't enough information to call it a match or a mismatch, so it reads as "no mix info"
/// rather than guessing.
private func mixCheck(trackTitle: String, candidateVersion: String?) -> MixCheck {
    let trackVersion = FuzzyMatch.splitVersion(trackTitle).version
    guard let a = trackVersion, let b = candidateVersion else { return .unknown }
    return FuzzyMatch.versionSimilarity(a, b) >= FuzzyMatch.versionMatchThreshold ? .same : .different
}

/// Splits `original` into (text, highlighted mix/version substring) for display, using
/// FuzzyMatch.splitVersion to find the version fragment and a plain substring search to
/// locate it in the original (un-normalized) casing/punctuation.
@ViewBuilder
private func compareLine(icon: String, original: String) -> some View {
    let version = FuzzyMatch.splitVersion(original).version
    HStack(alignment: .firstTextBaseline, spacing: 6) {
        Image(systemName: icon).font(.caption).foregroundStyle(.secondary)
        if let version, let range = original.range(of: version, options: [.caseInsensitive]) {
            (Text(original[..<range.lowerBound])
             + Text(original[range]).bold().foregroundStyle(.orange)
             + Text(original[range.upperBound...]))
                .font(.system(size: 13))
                .lineLimit(2)
        } else {
            Text(original)
                .font(.system(size: 13))
                .lineLimit(2)
        }
    }
}

// MARK: - Review section

private struct ReviewRow: Identifiable {
    let track: TrackEntity
    let candidates: [ScoredCandidate]
    var id: String { track.trackMBID }
    var top: ScoredCandidate? { candidates.first }
    var score: Double { top?.combinedScore ?? 0 }
    var mixCheck: MixCheck { rowMixCheck(trackTitle: track.title, candidateVersion: top?.version) }
}

// Renamed wrapper (vs. the file-scope `mixCheck` function) so it's callable from inside
// ReviewRow without shadowing the struct's own `mixCheck` stored property of the same name.
private func rowMixCheck(trackTitle: String, candidateVersion: String?) -> MixCheck {
    mixCheck(trackTitle: trackTitle, candidateVersion: candidateVersion)
}

private struct ReviewMasterDetailView: View {
    let tracks: [TrackEntity]
    let coordinator: FileMatchCoordinator
    @Environment(AudioPlaybackController.self) private var playback

    @State private var selection: Set<String> = []
    @State private var sortOrder: [KeyPathComparator<ReviewRow>] = [KeyPathComparator(\.score, order: .reverse)]
    @State private var mixFilters: Set<MixCheck> = []
    @State private var chosenCandidateIndex: Int = 0
    @State private var previewPendingPath: String? = nil
    @State private var showFileSearch = false
    @State private var confirmBatchDialog = false
    @AppStorage("fileMatchesTableWidthFraction") private var tableWidthFraction: Double = 0.6

    // Same title-score floor Stage 2 uses for its confident tier (FileMatchCoordinator's
    // _scoreCandidates: titleOK = titleScore >= 0.8) — reused here to define "high confidence"
    // for the batch mix-match confirm.
    private let confidentTitleFloor = 0.8

    private var rows: [ReviewRow] {
        tracks.map { ReviewRow(track: $0, candidates: coordinator.reviewCandidates[$0.trackMBID] ?? []) }
    }

    private var filteredRows: [ReviewRow] {
        mixFilters.isEmpty ? rows : rows.filter { mixFilters.contains($0.mixCheck) }
    }

    private var sortedRows: [ReviewRow] { filteredRows.sorted(using: sortOrder) }

    private var currentRow: ReviewRow? {
        guard selection.count == 1, let id = selection.first else { return nil }
        return sortedRows.first(where: { $0.id == id })
    }

    private var matchingMixCandidates: [(row: ReviewRow, candidate: ScoredCandidate)] {
        sortedRows.compactMap { row in
            guard let top = row.top, row.mixCheck == .same, top.titleScore >= confidentTitleFloor,
                  !isDuplicateFile(row) else { return nil }
            return (row, top)
        }
    }

    // MARK: - Duplicate best-guess file (B2)
    //
    // Several Discogs tracks can propose the same file as their best guess (different
    // mixes, one physical file). Batch-confirming those would silently award the file to
    // whichever row happened to be processed, so they're marked and kept out of batch
    // confirms; a manual single-row Confirm still works — the user may genuinely own only
    // one of the mixes.
    private var duplicateFilePaths: Set<String> {
        var counts: [String: Int] = [:]
        for row in rows {
            guard let path = row.top?.filePath else { continue }
            counts[path, default: 0] += 1
        }
        return Set(counts.filter { $0.value > 1 }.keys)
    }

    private func isDuplicateFile(_ row: ReviewRow) -> Bool {
        guard let path = row.top?.filePath else { return false }
        return duplicateFilePaths.contains(path)
    }

    private func otherTracksWanting(_ row: ReviewRow) -> [ReviewRow] {
        guard let path = row.top?.filePath else { return [] }
        return rows.filter { $0.id != row.id && $0.top?.filePath == path }
    }

    private var selectedNonDuplicateCount: Int {
        sortedRows.filter { selection.contains($0.id) && !isDuplicateFile($0) }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            filterAndBatchBar
            GeometryReader { totalGeo in
                HSplitView {
                    table
                        .frame(minWidth: 360, idealWidth: totalGeo.size.width * tableWidthFraction)
                        .background(splitWidthObserver(totalWidth: totalGeo.size.width))
                    detailPane
                        .frame(minWidth: 320)
                        .layoutPriority(1)
                }
            }
        }
        .onChange(of: currentRow?.id) { _, _ in chosenCandidateIndex = 0 }
    }

    // ponytail: SwiftUI's HSplitView exposes no binding for divider position, so we read
    // the table pane's live width via a background GeometryReader (fires during drag too)
    // and persist it as a fraction of the total — the closest native-API way to remember
    // the divider without dropping to an NSSplitView-delegate bridge.
    @ViewBuilder
    private func splitWidthObserver(totalWidth: CGFloat) -> some View {
        GeometryReader { paneGeo in
            Color.clear
                .onChange(of: paneGeo.size.width) { _, newWidth in
                    guard totalWidth > 0 else { return }
                    tableWidthFraction = newWidth / totalWidth
                }
        }
    }

    // MARK: - Filter chips + batch actions (B3, B4)

    private var filterAndBatchBar: some View {
        HStack(spacing: 8) {
            ForEach(MixCheck.allCases, id: \.self) { chip($0) }
            Spacer()
            if selection.count > 1 {
                Button("Confirm \(selectedNonDuplicateCount) selected") { confirmSelected() }
                    .controlSize(.small)
                    .disabled(selectedNonDuplicateCount == 0)
            }
            if !matchingMixCandidates.isEmpty {
                Button("Confirm \(matchingMixCandidates.count) same-mix matches") {
                    confirmBatchDialog = true
                }
                .controlSize(.small)
                .confirmationDialog(
                    "Confirm \(matchingMixCandidates.count) tracks with a matching mix?",
                    isPresented: $confirmBatchDialog, titleVisibility: .visible
                ) {
                    Button("Confirm \(matchingMixCandidates.count)") { confirmMatchingMix() }
                    Button("Cancel", role: .cancel) {}
                }
            }
        }
    }

    @ViewBuilder
    private func chip(_ filter: MixCheck) -> some View {
        let active = mixFilters.contains(filter)
        Button {
            if active { mixFilters.remove(filter) } else { mixFilters.insert(filter) }
        } label: {
            Text("\(filter.symbol) \(filter.label)")
                .font(.caption)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(active ? filter.tint.opacity(0.25) : Color.secondary.opacity(0.08), in: Capsule())
                .foregroundStyle(active ? filter.tint : Color.secondary)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Table (A2)

    private var table: some View {
        Table(sortedRows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Discogs track") { row in
                HStack(spacing: 5) {
                    Text("\(row.track.artistCredit) – \(row.track.title)").lineLimit(1)
                    if row.mixCheck != .unknown {
                        Text(row.mixCheck.symbol)
                            .font(.caption.bold())
                            .foregroundStyle(row.mixCheck.tint)
                            .help(row.mixCheck.label)
                            .accessibilityLabel(row.mixCheck.label)
                    }
                }
            }
            TableColumn("Best-guess file") { row in
                HStack(spacing: 4) {
                    Text(row.top.map { URL(fileURLWithPath: $0.filePath).lastPathComponent } ?? "—")
                        .foregroundStyle(.secondary).lineLimit(1)
                    if isDuplicateFile(row) {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .help("Also the best guess for another track — see detail pane")
                            .accessibilityLabel("Duplicate best-guess file, also proposed for another track")
                    }
                }
            }
            TableColumn("Score", value: \.score) { row in
                Text(row.top != nil ? String(format: "%.2f", row.score) : "—")
                    .font(.caption.monospacedDigit())
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(56)
        }
        // B1 — keyboard review. ↑/↓ row movement is Table's native behavior; these add the rest.
        // Return is deliberately NOT handled here — NSTableView (which backs Table) swallows it
        // as its own row-activation key before onKeyPress ever sees it. Confirm's
        // .keyboardShortcut(.defaultAction) in the detail pane covers Return instead.
        .onKeyPress("s") { skipCurrent(); return .handled }
        .onKeyPress(.delete) { skipCurrent(); return .handled }
        .onKeyPress(.space) { playChosen(); return .handled }
        .onKeyPress("1") { chooseCandidate(0); return .handled }
        .onKeyPress("2") { chooseCandidate(1); return .handled }
        .onKeyPress("3") { chooseCandidate(2); return .handled }
        .onKeyPress("4") { chooseCandidate(3); return .handled }
        .onKeyPress("5") { chooseCandidate(4); return .handled }
    }

    // MARK: - Detail pane (A4)

    @ViewBuilder
    private var detailPane: some View {
        if selection.count > 1 {
            VStack(spacing: 12) {
                Text("\(selection.count) tracks selected").font(.headline)
                Button("Confirm \(selection.count) with best guess") { confirmSelected() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let row = currentRow {
            singleRowDetailPane(row)
        } else {
            Text("Select a track to review")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func singleRowDetailPane(_ row: ReviewRow) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                compareLine(icon: "opticaldisc", original: "\(row.track.artistCredit) – \(row.track.title)")
                if let top = row.top {
                    compareLine(icon: "doc", original: URL(fileURLWithPath: top.filePath).lastPathComponent)
                }

                if isDuplicateFile(row) {
                    let others = otherTracksWanting(row)
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Also the best guess for \(others.count) other track\(others.count == 1 ? "" : "s")",
                              systemImage: "arrow.triangle.branch")
                            .font(.caption).foregroundStyle(.orange)
                        ForEach(others) { other in
                            Text("• \(other.track.artistCredit) – \(other.track.title)")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .padding(8)
                    .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                }

                if row.candidates.isEmpty {
                    Text("Re-run scan to load candidates.")
                        .font(.caption).foregroundStyle(.tertiary)
                } else {
                    Divider()
                    Text("Candidates")
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                    ForEach(Array(row.candidates.enumerated()), id: \.offset) { index, candidate in
                        candidateRow(row: row, index: index, candidate: candidate)
                    }
                }

                if let state = coordinator.verifyStates[row.track.trackMBID] {
                    verifyBadge(state)
                }

                Divider()
                HStack(spacing: 8) {
                    // The chosen candidate's mix check decides the label only — confirming works
                    // for every mix-check state (same/different/unknown); the user always decides.
                    Button(chosenMixCheck(row) == .different ? "Confirm anyway" : "Confirm") {
                        confirmChosen()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!row.candidates.indices.contains(chosenCandidateIndex))

                    Button("Skip") { skipCurrent() }
                        .foregroundStyle(.secondary)

                    Divider().frame(height: 16)

                    Button("Browse…") { browseFile(row) }.controlSize(.small)
                    Button("Search files…") { showFileSearch = true }.controlSize(.small)
                    if row.candidates.indices.contains(chosenCandidateIndex) {
                        Button("Verify with fingerprint") {
                            let path = row.candidates[chosenCandidateIndex].filePath
                            Task {
                                await coordinator.verifyWithFingerprint(trackMBID: row.track.trackMBID,
                                                                        recordingMBID: row.track.recordingMBID,
                                                                        filePath: path)
                            }
                        }
                        .controlSize(.small)
                        .disabled(coordinator.verifyStates[row.track.trackMBID] != nil)
                    }
                }

                Text("↑↓ move · ⏎ confirm · S/⌫ skip · Space preview · 1–5 pick candidate")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            .padding()
        }
        .sheet(isPresented: $showFileSearch) {
            FileSearchSheet(trackMBID: row.track.trackMBID, coordinator: coordinator, isPresented: $showFileSearch)
        }
        .onChange(of: playback.duration) { _, newValue in
            guard let pending = previewPendingPath, playback.currentFilePath == pending, newValue > 0 else { return }
            playback.seek(toFraction: 0.3)
            previewPendingPath = nil
        }
    }

    @ViewBuilder
    private func candidateRow(row: ReviewRow, index: Int, candidate: ScoredCandidate) -> some View {
        let isChosen = index == chosenCandidateIndex
        let mc = mixCheck(trackTitle: row.track.title, candidateVersion: candidate.version)
        Button {
            chosenCandidateIndex = index
        } label: {
            HStack(spacing: 8) {
                Text("\(index + 1)")
                    .font(.caption2.monospacedDigit())
                    .frame(width: 14)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(candidate.fileName).font(.caption).lineLimit(1).truncationMode(.middle)
                    HStack(spacing: 6) {
                        Text("\(mc.symbol) \(mc.label)").font(.caption2).foregroundStyle(mc.tint)
                        Text(String(format: "%.2f", candidate.combinedScore))
                            .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if playback.currentFilePath == candidate.filePath && playback.isPlaying {
                    Image(systemName: "waveform").foregroundStyle(Color.accentColor)
                }
            }
            .padding(6)
            .background(isChosen ? Color.accentColor.opacity(0.15) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func verifyBadge(_ state: FileMatchCoordinator.VerifyState) -> some View {
        switch state {
        case .running:
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text("Fingerprinting…").font(.caption2).foregroundStyle(.secondary)
            }
        case .confirmed(let score):
            Label(String(format: "Fingerprint verified ✓  (score %.2f)", score), systemImage: "checkmark.seal.fill")
                .font(.caption2).foregroundStyle(.green)
        case .conflicted(let title):
            Label("Fingerprint says: \(title)", systemImage: "exclamationmark.triangle.fill")
                .font(.caption2).foregroundStyle(.red)
        case .failed(let msg):
            Label("Verify failed: \(msg)", systemImage: "xmark.circle.fill")
                .font(.caption2).foregroundStyle(.orange)
        }
    }

    // MARK: - Actions (B1, B2, B5)

    /// Mix check for whichever candidate is currently chosen (1–5 picker) — nil if none.
    private func chosenMixCheck(_ row: ReviewRow) -> MixCheck? {
        guard row.candidates.indices.contains(chosenCandidateIndex) else { return nil }
        return mixCheck(trackTitle: row.track.title, candidateVersion: row.candidates[chosenCandidateIndex].version)
    }

    private func confirmChosen() {
        guard let row = currentRow, row.candidates.indices.contains(chosenCandidateIndex) else { return }
        let path = row.candidates[chosenCandidateIndex].filePath
        let next = nextRowID(after: row.id)
        coordinator.confirmMatch(trackMBID: row.track.trackMBID, filePath: path)
        playback.stop()
        selection = next.map { [$0] } ?? []
    }

    private func skipCurrent() {
        guard let row = currentRow else { return }
        let next = nextRowID(after: row.id)
        coordinator.skipTrack(trackMBID: row.track.trackMBID)
        playback.stop()
        selection = next.map { [$0] } ?? []
    }

    private func playChosen() {
        guard let row = currentRow, row.candidates.indices.contains(chosenCandidateIndex) else { return }
        let path = row.candidates[chosenCandidateIndex].filePath
        previewPendingPath = path
        playback.play(filePath: path)
    }

    private func chooseCandidate(_ index: Int) {
        guard let row = currentRow, row.candidates.indices.contains(index) else { return }
        chosenCandidateIndex = index
        playback.stop()
    }

    private func nextRowID(after id: String) -> String? {
        guard let idx = sortedRows.firstIndex(where: { $0.id == id }) else { return nil }
        if idx + 1 < sortedRows.count { return sortedRows[idx + 1].id }
        if idx > 0 { return sortedRows[idx - 1].id }
        return nil
    }

    private func confirmSelected() {
        for id in selection {
            guard let row = sortedRows.first(where: { $0.id == id }), let top = row.top,
                  !isDuplicateFile(row) else { continue }
            coordinator.confirmMatch(trackMBID: row.track.trackMBID, filePath: top.filePath)
        }
        selection = []
    }

    private func confirmMatchingMix() {
        for entry in matchingMixCandidates {
            coordinator.confirmMatch(trackMBID: entry.row.track.trackMBID, filePath: entry.candidate.filePath)
        }
        selection = []
    }

    private func browseFile(_ row: ReviewRow) {
#if os(macOS)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = libraryRootURL()
        panel.message = "Choose an audio file for this track"
        panel.prompt = "Select"
        if panel.runModal() == .OK, let url = panel.url {
            coordinator.assignFile(trackMBID: row.track.trackMBID, url: url)
        }
#endif
    }
}

// MARK: - No Match section

private struct NoMatchRow: Identifiable {
    let track: TrackEntity
    var id: String { track.trackMBID }
}

private struct NoMatchMasterDetailView: View {
    let tracks: [TrackEntity]
    let coordinator: FileMatchCoordinator

    @State private var selection: Set<String> = []
    @State private var showFileSearch = false

    private var rows: [NoMatchRow] { tracks.map(NoMatchRow.init) }
    private var currentRow: NoMatchRow? {
        guard selection.count == 1, let id = selection.first else { return nil }
        return rows.first(where: { $0.id == id })
    }

    var body: some View {
        HStack(spacing: 0) {
            Table(rows, selection: $selection) {
                TableColumn("Discogs track") { row in
                    Text("\(row.track.artistCredit) – \(row.track.title)").lineLimit(1)
                }
            }
            .onKeyPress("s") { skip(); return .handled }
            .onKeyPress(.delete) { skip(); return .handled }
            .frame(minWidth: 360)
            Divider()
            detailPane.frame(minWidth: 260)
        }
    }

    @ViewBuilder
    private var detailPane: some View {
        if let row = currentRow {
            VStack(alignment: .leading, spacing: 12) {
                Text("\(row.track.artistCredit) – \(row.track.title)")
                    .font(.system(size: 15, weight: .medium))
                Spacer(minLength: 0)
                HStack(spacing: 8) {
                    Button("Browse…") { browseFile(row) }.controlSize(.small)
                    Button("Search files…") { showFileSearch = true }.controlSize(.small)
                    Button("Skip") { skip() }.controlSize(.small).foregroundStyle(.secondary)
                }
                Text("S/⌫ skip").font(.caption2).foregroundStyle(.tertiary)
            }
            .padding()
            .sheet(isPresented: $showFileSearch) {
                FileSearchSheet(trackMBID: row.track.trackMBID, coordinator: coordinator, isPresented: $showFileSearch)
            }
        } else {
            Text("Select a track")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func skip() {
        guard let row = currentRow else { return }
        let next = nextID(after: row.id)
        coordinator.skipTrack(trackMBID: row.track.trackMBID)
        selection = next.map { [$0] } ?? []
    }

    private func nextID(after id: String) -> String? {
        guard let idx = rows.firstIndex(where: { $0.id == id }) else { return nil }
        if idx + 1 < rows.count { return rows[idx + 1].id }
        if idx > 0 { return rows[idx - 1].id }
        return nil
    }

    private func browseFile(_ row: NoMatchRow) {
#if os(macOS)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = libraryRootURL()
        panel.message = "Assign an audio file for this track"
        panel.prompt = "Assign"
        if panel.runModal() == .OK, let url = panel.url {
            coordinator.assignFile(trackMBID: row.track.trackMBID, url: url)
        }
#endif
    }
}

// MARK: - Confident section

private struct ConfidentRow: Identifiable {
    let track: TrackEntity
    var id: String { track.trackMBID }
    var fileName: String {
        track.primaryLocalFilePath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "—"
    }
    var format: String {
        track.primaryLocalFilePath.map { URL(fileURLWithPath: $0).pathExtension.uppercased() } ?? ""
    }
}

private struct ConfidentMasterDetailView: View {
    let tracks: [TrackEntity]
    let coordinator: FileMatchCoordinator

    @State private var selection: Set<String> = []

    private var rows: [ConfidentRow] { tracks.map(ConfidentRow.init) }
    private var currentRow: ConfidentRow? {
        guard selection.count == 1, let id = selection.first else { return nil }
        return rows.first(where: { $0.id == id })
    }

    var body: some View {
        HStack(spacing: 0) {
            Table(rows, selection: $selection) {
                TableColumn("Discogs track") { row in
                    Text("\(row.track.artistCredit) – \(row.track.title)").lineLimit(1)
                }
                TableColumn("File") { row in
                    Text(row.fileName).foregroundStyle(.secondary).lineLimit(1)
                }
                TableColumn("Format") { row in
                    Text(row.format).font(.caption2)
                }
            }
            .frame(minWidth: 400)
            Divider()
            detailPane.frame(minWidth: 220)
        }
    }

    @ViewBuilder
    private var detailPane: some View {
        if let row = currentRow {
            VStack(alignment: .leading, spacing: 12) {
                Text("\(row.track.artistCredit) – \(row.track.title)")
                    .font(.system(size: 15, weight: .medium))
                Text(row.fileName)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
                Spacer(minLength: 0)
                HStack(spacing: 8) {
                    Button("Change") { changeFile(row) }.controlSize(.small)
                    Button("Unlink") { coordinator.unlinkMatch(trackMBID: row.track.trackMBID) }
                        .controlSize(.small).foregroundStyle(.red)
                }
            }
            .padding()
        } else {
            Text("Select a track")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func changeFile(_ row: ConfidentRow) {
#if os(macOS)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = libraryRootURL()
        panel.message = "Choose a replacement audio file"
        panel.prompt = "Select"
        if panel.runModal() == .OK, let url = panel.url {
            coordinator.assignFile(trackMBID: row.track.trackMBID, url: url)
        }
#endif
    }
}

// MARK: - File search sheet

private struct FileSearchSheet: View {
    let trackMBID: String
    let coordinator: FileMatchCoordinator
    @Binding var isPresented: Bool

    @State private var query = ""
    @Query(sort: \LocalFileEntity.fileName) private var allFiles: [LocalFileEntity]

    private var results: [LocalFileEntity] {
        if query.isEmpty {
            return Array(allFiles.prefix(100))
        }
        let q = query.lowercased()
        return Array(
            allFiles.filter {
                $0.fileName.lowercased().contains(q) ||
                $0.filePath.lowercased().contains(q)
            }
            .prefix(200)
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Search Files")
                    .font(.headline)
                Spacer()
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()

            Divider()

            TextField("Filename or path…", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding()

            if results.isEmpty {
                Spacer()
                if query.isEmpty {
                    Text("Type to search \(allFiles.count.formatted()) indexed files")
                        .foregroundStyle(.secondary)
                } else {
                    Text("No results for \"\(query)\"")
                        .foregroundStyle(.secondary)
                }
                Spacer()
            } else {
                List(results, id: \.filePath) { file in
                    Button {
                        coordinator.assignFile(trackMBID: trackMBID,
                                               url: URL(fileURLWithPath: file.filePath))
                        isPresented = false
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(file.fileName)
                                .font(.system(size: 13))
                                .foregroundStyle(.primary)
                            Text(file.filePath)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(minWidth: 520, minHeight: 440)
    }
}
