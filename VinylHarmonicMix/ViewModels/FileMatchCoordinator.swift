import Foundation
import SwiftData

@MainActor
@Observable
final class FileMatchCoordinator {

    enum Phase { case idle, indexing, narrowing, confirming, paused, completed, cancelled }

    var phase: Phase = .idle
    var showPanel: Bool = false

    var indexedCount: Int = 0
    var totalTracks: Int = 0
    var processedTracks: Int = 0
    var matchedCount: Int = 0
    var unconfirmedCount: Int = 0
    var noCandidateCount: Int = 0
    var currentTrackLabel: String = ""
    var hasRunTestBatch: Bool = false
    var lastError: String? = nil

    private let context: ModelContext
    private var scanTask: Task<Void, Never>?
    private var pendingLimit: Int? = nil

    static let formatPriority: [String: Int] = [
        "flac": 0, "aiff": 1, "wav": 2, "m4a": 3,
        "mp3": 4, "ogg": 5, "opus": 6, "mp4": 7
    ]

    var shouldShowPanel: Bool {
        switch phase {
        case .idle: return false
        default: return true
        }
    }

    init(context: ModelContext) { self.context = context }

    // MARK: - Controls

    func startTestBatch(size: Int = 150) {
        guard case .idle = phase else { return }
        hasRunTestBatch = false
        beginScan(limit: size)
    }

    func startFullScan() {
        guard hasRunTestBatch || phase == .idle else { return }
        beginScan(limit: nil)
    }

    func pause() {
        scanTask?.cancel()
        scanTask = nil
        phase = .paused
    }

    func resume() {
        guard case .paused = phase else { return }
        beginScan(limit: pendingLimit)
    }

    func cancel() {
        scanTask?.cancel()
        scanTask = nil
        phase = .cancelled
    }

    func dismissPanel() {
        phase = .idle
        indexedCount = 0; totalTracks = 0; processedTracks = 0
        matchedCount = 0; unconfirmedCount = 0; noCandidateCount = 0
        currentTrackLabel = ""; lastError = nil
    }

    // MARK: - Live stats helpers (for stats view)

    var matchedFileCount: Int {
        (try? context.fetchCount(FetchDescriptor<TrackEntity>(
            predicate: #Predicate { $0.fileMatchState == "matched" }
        ))) ?? 0
    }

    var unconfirmedFileCount: Int {
        (try? context.fetchCount(FetchDescriptor<TrackEntity>(
            predicate: #Predicate { $0.fileMatchState == "candidateUnconfirmed" }
        ))) ?? 0
    }

    var noCandidateFileCount: Int {
        (try? context.fetchCount(FetchDescriptor<TrackEntity>(
            predicate: #Predicate { $0.fileMatchState == "noCandidate" }
        ))) ?? 0
    }

    var totalTracksWithRecordingMBID: Int {
        let all = (try? context.fetch(FetchDescriptor<TrackEntity>())) ?? []
        return all.filter { !$0.recordingMBID.isEmpty }.count
    }

    // MARK: - Internal

    private func beginScan(limit: Int?) {
        pendingLimit = limit
        showPanel = true
        phase = .indexing
        indexedCount = 0; processedTracks = 0
        matchedCount = 0; unconfirmedCount = 0; noCandidateCount = 0
        currentTrackLabel = ""; lastError = nil

        scanTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }

            // ── Phase 1: Index files ──
            await self.runPhase1()
            if Task.isCancelled { return }

            // ── Phase 2: Narrow ──
            await MainActor.run { self.phase = .narrowing }
            let candidates = await self.runPhase2(limit: limit)
            if Task.isCancelled { return }

            // ── Phase 3: Confirm via AcoustID ──
            await MainActor.run {
                self.phase = .confirming
                self.totalTracks = candidates.count
            }
            await self.runPhase3(candidates: candidates)
            if Task.isCancelled { return }

            await MainActor.run {
                try? self.context.save()
                self.phase = .completed
                if limit != nil { self.hasRunTestBatch = true }
            }
        }
    }

    // MARK: - Phase 1: Index

    private struct FileInfo: Sendable {
        let path: String
        let name: String
        let format: String
        let size: Int?
    }

    private func runPhase1() async {
        guard let url = LocalLibraryService.resolveLibraryBookmark() else { return }

        let audioExtensions: Set<String> = ["flac","mp3","aiff","aif","wav","m4a","mp4","ogg","opus"]
        let skipDirs: Set<String> = ["#recycle","@eaDir",".Trashes",".Spotlight-V100"]

        // Fetch existing paths on main actor to avoid re-indexing
        let existingPaths: Set<String> = await MainActor.run {
            let all = (try? self.context.fetch(FetchDescriptor<LocalFileEntity>())) ?? []
            return Set(all.map(\.filePath))
        }

        guard let enumerator = FileManager().enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        var batch: [FileInfo] = []
        var examined = 0

        for case let fileURL as URL in enumerator {
            if Task.isCancelled { break }
            examined += 1

            let name = fileURL.lastPathComponent
            if skipDirs.contains(name) { enumerator.skipDescendants(); continue }

            let ext = fileURL.pathExtension.lowercased()
            guard audioExtensions.contains(ext) else { continue }

            let path = fileURL.path
            if existingPaths.contains(path) { continue }

            let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize
            batch.append(FileInfo(path: path, name: name, format: ext, size: size))

            if batch.count >= 200 {
                let toInsert = batch; batch = []
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    for f in toInsert {
                        let e = LocalFileEntity(filePath: f.path, fileName: f.name, format: f.format, fileSizeBytes: f.size)
                        self.context.insert(e)
                    }
                    self.indexedCount += toInsert.count
                    try? self.context.save()
                }
            }

            if examined % 250 == 0 {
                let folder = fileURL.deletingLastPathComponent().lastPathComponent
                await MainActor.run { self.currentTrackLabel = folder }
            }
        }

        if !batch.isEmpty {
            let toInsert = batch
            await MainActor.run { [weak self] in
                guard let self else { return }
                for f in toInsert {
                    let e = LocalFileEntity(filePath: f.path, fileName: f.name, format: f.format, fileSizeBytes: f.size)
                    self.context.insert(e)
                }
                self.indexedCount += toInsert.count
                try? self.context.save()
            }
        }
    }

    // MARK: - Phase 2: Narrow

    private struct TrackSummary: Sendable {
        let trackMBID: String
        let recordingMBID: String
        let artist: String
        let title: String
        let fileMatchState: String
    }

    private struct FileSummary: Sendable {
        let filePath: String
        let fileName: String
        let format: String
        let artistFolderKey: String
        let cachedFingerprint: String?
        let cachedDuration: Int?
    }

    private func runPhase2(limit: Int?) async -> [(track: TrackSummary, candidates: [FileSummary])] {
        // Snapshot everything on main actor
        let (trackSummaries, fileSummaries) = await MainActor.run { () -> ([TrackSummary], [FileSummary]) in
            let allTracks = (try? self.context.fetch(FetchDescriptor<TrackEntity>())) ?? []
            let eligible = Array(allTracks
                .filter { !$0.recordingMBID.isEmpty && $0.fileMatchState == "unscanned" })
            let scoped = limit.map { Array(eligible.prefix($0)) } ?? eligible

            let tracks = scoped.map { t -> TrackSummary in
                let artist = t.artistCredit.isEmpty
                    ? (t.collectionItem?.basicInformation?.artists.first?.name ?? "")
                    : t.artistCredit
                return TrackSummary(trackMBID: t.trackMBID, recordingMBID: t.recordingMBID,
                                    artist: artist, title: t.title, fileMatchState: t.fileMatchState)
            }

            let allFiles = (try? self.context.fetch(FetchDescriptor<LocalFileEntity>())) ?? []
            let files = allFiles.map { f -> FileSummary in
                let parentURL = URL(fileURLWithPath: f.filePath).deletingLastPathComponent()
                let parentName = parentURL.lastPathComponent
                let key: String
                if parentName.first?.isNumber == true {
                    key = FuzzyMatch.normalize(parentURL.deletingLastPathComponent().lastPathComponent)
                } else {
                    key = FuzzyMatch.normalize(parentName)
                }
                return FileSummary(filePath: f.filePath, fileName: f.fileName, format: f.format,
                                   artistFolderKey: key, cachedFingerprint: f.fingerprint,
                                   cachedDuration: f.durationSeconds)
            }
            return (tracks, files)
        }

        if trackSummaries.isEmpty || fileSummaries.isEmpty { return [] }

        // Build artist-bucket dictionary (off main actor — pure computation)
        var buckets: [String: [FileSummary]] = [:]
        for file in fileSummaries {
            let key = FuzzyMatch.bucketKey(file.artistFolderKey)
            buckets[key, default: []].append(file)
        }

        // For each track, find candidates
        var result: [(track: TrackSummary, candidates: [FileSummary])] = []

        for track in trackSummaries {
            if Task.isCancelled { break }

            let artistKey = FuzzyMatch.bucketKey(track.artist)

            // Collect files from matching buckets (exact key + adjacent 1-char variants)
            var pool: [FileSummary] = buckets[artistKey] ?? []
            // Also try without leading article stripping to catch edge cases
            let rawKey = String(FuzzyMatch.normalize(track.artist).prefix(4))
            if rawKey != artistKey, let extra = buckets[rawKey] { pool += extra }

            // If the pool is tiny, also include files whose folder key is close
            // (handles "The X" vs "X, The" variations that escaped bucket normalization)
            if pool.count < 5 {
                for (bucketK, files) in buckets {
                    if bucketK != artistKey && bucketK != rawKey {
                        let sim = FuzzyMatch.similarity(bucketK, artistKey)
                        if sim >= 0.6 { pool += files }
                    }
                }
            }

            let trackStr = "\(track.artist) \(track.title)"
            let scored: [(FileSummary, Double)] = pool.compactMap { file in
                let stem = String(file.fileName.prefix(file.fileName.count - file.format.count - 1))
                let sim = FuzzyMatch.similarity(trackStr, stem)
                return sim >= 0.55 ? (file, sim) : nil
            }

            let topCandidates = scored
                .sorted { lhs, rhs in
                    if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
                    let lPrio = FileMatchCoordinator.formatPriority[lhs.0.format] ?? 99
                    let rPrio = FileMatchCoordinator.formatPriority[rhs.0.format] ?? 99
                    return lPrio < rPrio
                }
                .prefix(5)
                .map(\.0)

            result.append((track: track, candidates: Array(topCandidates)))
        }

        return result
    }

    // MARK: - Phase 3: Confirm

    private func runPhase3(candidates: [(track: TrackSummary, candidates: [FileSummary])]) async {
        guard let fpcalcPath = LocalLibraryService.fpcalcPath(),
              let apiKey = KeychainService.shared.load(for: .acoustIDKey),
              !apiKey.isEmpty else {
            await MainActor.run { lastError = "fpcalc or AcoustID key not configured" }
            return
        }

        let acoustID = AcoustIDClient(fpcalcPath: fpcalcPath, apiKey: apiKey)
        var saveCounter = 0

        for (track, fileCandidates) in candidates {
            if Task.isCancelled { break }

            await MainActor.run { self.currentTrackLabel = "\(track.artist) — \(track.title)" }

            if fileCandidates.isEmpty {
                await MainActor.run {
                    self.updateMatchState(trackMBID: track.trackMBID, state: "noCandidate")
                    self.noCandidateCount += 1
                    self.processedTracks += 1
                }
                continue
            }

            // Sort candidates: format priority first, then fuzzy score
            let sortedCandidates = fileCandidates.sorted {
                (FileMatchCoordinator.formatPriority[$0.format] ?? 99) <
                (FileMatchCoordinator.formatPriority[$1.format] ?? 99)
            }

            var matchedFilePath: String? = nil
            var matchedScore: Double = 0
            var allReturnedMBIDs: [String] = []
            var bestCandidateForUnconfirmed: FileSummary? = nil

            for candidate in sortedCandidates.prefix(3) {
                if Task.isCancelled { break }

                // Get or compute fingerprint
                let fpResult: AcoustIDClient.FingerprintResult?
                if let cachedFP = candidate.cachedFingerprint, let cachedDur = candidate.cachedDuration {
                    fpResult = AcoustIDClient.FingerprintResult(duration: cachedDur, fingerprint: cachedFP)
                } else {
                    fpResult = try? await acoustID.fingerprint(filePath: candidate.filePath)
                    if let r = fpResult {
                        let fp = r.fingerprint; let dur = r.duration; let path = candidate.filePath
                        await MainActor.run {
                            self.cacheFingerprint(filePath: path, fingerprint: fp, duration: dur)
                        }
                    }
                }

                guard let fp = fpResult else { continue }

                let lookup = try? await acoustID.lookup(fingerprint: fp.fingerprint, duration: fp.duration)
                guard let lookup else { continue }

                allReturnedMBIDs.append(contentsOf: lookup.recordingMBIDs)

                if lookup.recordingMBIDs.contains(track.recordingMBID) {
                    matchedFilePath = candidate.filePath
                    matchedScore = lookup.topScore
                    if bestCandidateForUnconfirmed == nil { bestCandidateForUnconfirmed = candidate }
                    break
                }

                if bestCandidateForUnconfirmed == nil { bestCandidateForUnconfirmed = candidate }
            }

            // Store all returned MBIDs on all candidates
            for candidate in fileCandidates {
                let path = candidate.filePath; let mbids = allReturnedMBIDs
                await MainActor.run { self.setAcoustIDMBIDs(filePath: path, mbids: mbids) }
            }

            if let matchPath = matchedFilePath {
                let score = matchedScore; let tMBID = track.trackMBID
                await MainActor.run {
                    self.linkFile(filePath: matchPath, toTrackMBID: tMBID, score: score)
                    self.matchedCount += 1
                    self.processedTracks += 1
                }
            } else if let best = bestCandidateForUnconfirmed {
                let path = best.filePath; let tMBID = track.trackMBID
                await MainActor.run {
                    self.markUnconfirmed(filePath: path, trackMBID: tMBID)
                    self.unconfirmedCount += 1
                    self.processedTracks += 1
                }
            } else {
                await MainActor.run {
                    self.updateMatchState(trackMBID: track.trackMBID, state: "noCandidate")
                    self.noCandidateCount += 1
                    self.processedTracks += 1
                }
            }

            saveCounter += 1
            if saveCounter >= 10 {
                saveCounter = 0
                await MainActor.run { try? self.context.save() }
            }
        }
    }

    // MARK: - SwiftData helpers (all @MainActor)

    private func updateMatchState(trackMBID: String, state: String) {
        var d = FetchDescriptor<TrackEntity>(predicate: #Predicate { $0.trackMBID == trackMBID })
        d.fetchLimit = 1
        guard let track = try? context.fetch(d).first else { return }
        track.fileMatchState = state
    }

    private func cacheFingerprint(filePath: String, fingerprint: String, duration: Int) {
        var d = FetchDescriptor<LocalFileEntity>(predicate: #Predicate { $0.filePath == filePath })
        d.fetchLimit = 1
        guard let file = try? context.fetch(d).first else { return }
        file.fingerprint = fingerprint
        file.durationSeconds = duration
        file.fingerprintedAt = .now
    }

    private func setAcoustIDMBIDs(filePath: String, mbids: [String]) {
        var d = FetchDescriptor<LocalFileEntity>(predicate: #Predicate { $0.filePath == filePath })
        d.fetchLimit = 1
        guard let file = try? context.fetch(d).first else { return }
        file.acoustIDRecordingMBIDs = Array(Set(file.acoustIDRecordingMBIDs + mbids))
    }

    private func linkFile(filePath: String, toTrackMBID trackMBID: String, score: Double) {
        var td = FetchDescriptor<TrackEntity>(predicate: #Predicate { $0.trackMBID == trackMBID })
        td.fetchLimit = 1
        var fd = FetchDescriptor<LocalFileEntity>(predicate: #Predicate { $0.filePath == filePath })
        fd.fetchLimit = 1
        guard let track = try? context.fetch(td).first,
              let file  = try? context.fetch(fd).first else { return }

        // Insert-then-assign pattern (both already in context)
        file.track = track
        file.matchMethod = "fingerprint"
        file.matchScore = score
        track.fileMatchState = "matched"
        track.primaryLocalFilePath = filePath
    }

    private func markUnconfirmed(filePath: String, trackMBID: String) {
        var td = FetchDescriptor<TrackEntity>(predicate: #Predicate { $0.trackMBID == trackMBID })
        td.fetchLimit = 1
        guard let track = try? context.fetch(td).first else { return }
        track.fileMatchState = "candidateUnconfirmed"
        track.primaryLocalFilePath = filePath
    }
}
