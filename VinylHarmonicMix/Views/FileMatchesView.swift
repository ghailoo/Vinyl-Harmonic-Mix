import SwiftUI
import SwiftData
#if os(macOS)
import AppKit
#endif
import AVFoundation

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

    @State private var expandConfident = false
    @State private var expandReview    = true
    @State private var expandNoMatch   = false

    var body: some View {
        Group {
            if confidentTracks.isEmpty && reviewTracks.isEmpty && noMatchTracks.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("File Matches")
                            .font(.system(size: 28, weight: .bold))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.bottom, 4)

                        confidentSection
                        reviewSection
                        noMatchSection
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 20)
                }
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

    // MARK: - Confident section

    private var confidentSection: some View {
        sectionCard {
            DisclosureGroup(isExpanded: $expandConfident) {
                if confidentTracks.isEmpty {
                    Text("None yet.").font(.caption).foregroundStyle(.tertiary).padding(.top, 4)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(confidentTracks, id: \.trackMBID) { track in
                            ConfidentRowView(track: track, coordinator: coordinator)
                            if track.trackMBID != confidentTracks.last?.trackMBID {
                                Divider()
                            }
                        }
                    }
                    .padding(.top, 6)
                }
            } label: {
                HStack {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("Confident (\(confidentTracks.count))")
                        .font(.system(size: 16, weight: .semibold))
                }
            }
        }
    }

    // MARK: - Review section

    private var reviewSection: some View {
        sectionCard {
            DisclosureGroup(isExpanded: $expandReview) {
                if reviewTracks.isEmpty {
                    Text("None yet.").font(.caption).foregroundStyle(.tertiary).padding(.top, 4)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(reviewTracks, id: \.trackMBID) { track in
                            ReviewRowView(track: track, coordinator: coordinator)
                            if track.trackMBID != reviewTracks.last?.trackMBID {
                                Divider()
                            }
                        }
                    }
                    .padding(.top, 6)
                }
            } label: {
                HStack {
                    Image(systemName: "questionmark.circle.fill").foregroundStyle(.orange)
                    Text("Needs Review (\(reviewTracks.count))")
                        .font(.system(size: 16, weight: .semibold))
                }
            }
        }
    }

    // MARK: - No Match section

    private var noMatchSection: some View {
        sectionCard {
            DisclosureGroup(isExpanded: $expandNoMatch) {
                if noMatchTracks.isEmpty {
                    Text("None yet.").font(.caption).foregroundStyle(.tertiary).padding(.top, 4)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(noMatchTracks, id: \.trackMBID) { track in
                            NoMatchRowView(track: track, coordinator: coordinator)
                            if track.trackMBID != noMatchTracks.last?.trackMBID {
                                Divider()
                            }
                        }
                    }
                    .padding(.top, 6)
                }
            } label: {
                HStack {
                    Image(systemName: "circle").foregroundStyle(.secondary)
                    Text("No Match (\(noMatchTracks.count))")
                        .font(.system(size: 16, weight: .semibold))
                }
            }
        }
    }

    // MARK: - Card wrapper

    private func sectionCard<C: View>(@ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 0) { content() }
            .padding(16)
            .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Library root URL helper

private func libraryRootURL() -> URL? {
    guard let path = UserDefaults.standard.string(forKey: LocalLibraryService.displayPathKey) else { return nil }
    return URL(fileURLWithPath: path)
}

// MARK: - Confident row

private struct ConfidentRowView: View {
    let track: TrackEntity
    let coordinator: FileMatchCoordinator
    @Environment(AudioPlaybackController.self) private var playback

    private var filePath: String? { track.primaryLocalFilePath }

    private var fileName: String {
        guard let path = filePath else { return "—" }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    private var format: String {
        guard let path = filePath else { return "" }
        return URL(fileURLWithPath: path).pathExtension.uppercased()
    }

    // Whether THIS row's file is the one currently loaded in the player
    private var isThisActive: Bool {
        guard let path = filePath else { return false }
        return playback.currentFilePath == path
    }

    private var isThisPlaying: Bool { isThisActive && playback.isPlaying }

    private var progress: Double {
        guard isThisActive, playback.duration > 0 else { return 0 }
        return min(1, max(0, playback.currentTime / playback.duration))
    }

    private var errorForThisFile: String? {
        guard let path = filePath else { return nil }
        return playback.playbackErrors[path]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Main row
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green).font(.caption)
                    .padding(.top, 3)

                VStack(alignment: .leading, spacing: 3) {
                    Text("\(track.artistCredit) – \(track.title)")
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)

                    HStack(spacing: 6) {
                        Text(fileName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        if !format.isEmpty {
                            Text(format)
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 5).padding(.vertical, 2)
                                .background(Color.accentColor, in: Capsule())
                                .foregroundStyle(.white)
                        }
                    }
                }

                Spacer()

                HStack(spacing: 6) {
                    // Play / Pause button
                    if let path = filePath {
                        Button {
                            playback.play(filePath: path)
                        } label: {
                            Image(systemName: isThisPlaying ? "pause.circle.fill" : "play.circle.fill")
                                .font(.system(size: 20))
                                .foregroundStyle(isThisActive ? Color.accentColor : Color.secondary)
                                .contentTransition(.symbolEffect(.replace))
                        }
                        .buttonStyle(.plain)
                        .help(isThisPlaying ? "Pause" : "Play")
                    }
                    Button("Change") { pickFile() }
                        .controlSize(.small)
                    Button("Unlink") { coordinator.unlinkMatch(trackMBID: track.trackMBID) }
                        .controlSize(.small).foregroundStyle(.red)
                }
            }

            // Player area — shown only while this row's file is loaded
            if isThisActive {
                playerArea
                    .padding(.top, 6)
                    .padding(.leading, 22)  // align under the text column
            }
        }
        .padding(.vertical, 8)
    }

    // MARK: - Player area

    @ViewBuilder
    private var playerArea: some View {
        if let err = errorForThisFile {
            Label(err, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(3)
                .textSelection(.enabled)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                waveformArea
                    .frame(height: 44)

                if playback.duration > 0 {
                    Text("\(formatTime(playback.currentTime)) / \(formatTime(playback.duration))")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var waveformArea: some View {
        let state: AudioPlaybackController.WaveformState = filePath.map {
            playback.waveformState(for: $0)
        } ?? .idle

        switch state {
        case .ready(let peaks):
            WaveformView(peaks: peaks, progress: progress) { fraction in
                playback.seek(toFraction: fraction)
            }
            .clipShape(RoundedRectangle(cornerRadius: 4))

        case .loading:
            ZStack {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.secondary.opacity(0.1))
                HStack(spacing: 6) {
                    ProgressView().scaleEffect(0.6)
                    Text("Loading waveform…").font(.caption2).foregroundStyle(.secondary)
                }
            }

        case .failed:
            ZStack {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.secondary.opacity(0.08))
                Text("Waveform unavailable").font(.caption2).foregroundStyle(.tertiary)
            }

        case .idle:
            // Waveform generation hasn't started yet — kick it off
            Color.clear
                .onAppear {
                    if let path = filePath { playback.loadWaveformIfNeeded(filePath: path) }
                }
        }
    }

    // MARK: - Helpers

    private func formatTime(_ seconds: Double) -> String {
        let s = max(0, Int(seconds))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private func pickFile() {
#if os(macOS)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = libraryRootURL()
        panel.message = "Choose a replacement audio file"
        panel.prompt = "Select"
        if panel.runModal() == .OK, let url = panel.url {
            coordinator.assignFile(trackMBID: track.trackMBID, url: url)
        }
#endif
    }
}

// MARK: - Review row

private struct ReviewRowView: View {
    let track: TrackEntity
    let coordinator: FileMatchCoordinator

    @State private var showFileSearch = false

    private var candidates: [ScoredCandidate] {
        coordinator.reviewCandidates[track.trackMBID] ?? []
    }

    private var top: ScoredCandidate? { candidates.first }

    private var verifyState: FileMatchCoordinator.VerifyState? {
        coordinator.verifyStates[track.trackMBID]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Track label
            HStack(spacing: 6) {
                Image(systemName: "questionmark.circle.fill")
                    .foregroundStyle(.orange).font(.caption)
                Text("\(track.artistCredit) – \(track.title)")
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
            }

            if candidates.isEmpty {
                Text("Re-run scan to load candidates.")
                    .font(.caption).foregroundStyle(.tertiary)
            } else if let top {
                // Best-guess candidate
                HStack(spacing: 6) {
                    Text("Best guess:")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(URL(fileURLWithPath: top.filePath).lastPathComponent)
                        .font(.caption).foregroundStyle(.primary)
                        .lineLimit(1).truncationMode(.middle)
                    // baseScore == 0 means candidate was loaded from persisted paths
                    // (no live scan score available) — hide the numeric display.
                    if top.baseScore > 0 {
                        Text(String(format: "base %.2f · ver %.2f", top.baseScore, top.versionScore))
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }

                // Verification badge
                if let state = verifyState {
                    verifyBadge(state: state)
                }

                // Primary action row
                HStack(spacing: 8) {
                    Button("Confirm") {
                        coordinator.confirmMatch(trackMBID: track.trackMBID, filePath: top.filePath)
                    }
                    .controlSize(.small).buttonStyle(.borderedProminent)

                    // Pick another — show other candidates from this scan
                    if candidates.count > 1 {
                        Menu("Pick another ▾") {
                            ForEach(Array(candidates.dropFirst().enumerated()), id: \.offset) { _, c in
                                Button(URL(fileURLWithPath: c.filePath).lastPathComponent) {
                                    coordinator.confirmMatch(trackMBID: track.trackMBID, filePath: c.filePath)
                                }
                            }
                        }
                        .controlSize(.small)
                    }

                    Button("Skip") { coordinator.skipTrack(trackMBID: track.trackMBID) }
                        .controlSize(.small).foregroundStyle(.secondary)
                }

                // Manual override row
                HStack(spacing: 8) {
                    Button("Browse…") { browseFile() }
                        .controlSize(.small)

                    Button("Search files…") { showFileSearch = true }
                        .controlSize(.small)

                    Button("Verify with fingerprint") {
                        Task {
                            await coordinator.verifyWithFingerprint(
                                trackMBID: track.trackMBID,
                                recordingMBID: track.recordingMBID,
                                filePath: top.filePath
                            )
                        }
                    }
                    .controlSize(.small)
                    .disabled(verifyState != nil)
                }
            }
        }
        .padding(.vertical, 8)
        .sheet(isPresented: $showFileSearch) {
            FileSearchSheet(trackMBID: track.trackMBID, coordinator: coordinator,
                            isPresented: $showFileSearch)
        }
    }

    @ViewBuilder
    private func verifyBadge(state: FileMatchCoordinator.VerifyState) -> some View {
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

    private func browseFile() {
#if os(macOS)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = libraryRootURL()
        panel.message = "Choose an audio file for this track"
        panel.prompt = "Select"
        if panel.runModal() == .OK, let url = panel.url {
            coordinator.assignFile(trackMBID: track.trackMBID, url: url)
        }
#endif
    }
}

// MARK: - No Match row

private struct NoMatchRowView: View {
    let track: TrackEntity
    let coordinator: FileMatchCoordinator

    @State private var showFileSearch = false

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "circle")
                .foregroundStyle(.secondary).font(.caption)

            Text("\(track.artistCredit) – \(track.title)")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer()

            HStack(spacing: 6) {
                Button("Browse…") { browseFile() }.controlSize(.small)
                Button("Search files…") { showFileSearch = true }.controlSize(.small)
                Button("Skip") { coordinator.skipTrack(trackMBID: track.trackMBID) }
                    .controlSize(.small).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
        .sheet(isPresented: $showFileSearch) {
            FileSearchSheet(trackMBID: track.trackMBID, coordinator: coordinator,
                            isPresented: $showFileSearch)
        }
    }

    private func browseFile() {
#if os(macOS)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = libraryRootURL()
        panel.message = "Assign an audio file for this track"
        panel.prompt = "Assign"
        if panel.runModal() == .OK, let url = panel.url {
            coordinator.assignFile(trackMBID: track.trackMBID, url: url)
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
            // Header
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
