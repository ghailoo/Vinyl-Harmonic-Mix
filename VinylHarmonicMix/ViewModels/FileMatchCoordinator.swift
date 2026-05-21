import Foundation
import SwiftData
#if os(macOS)
import AppKit
#endif

@MainActor
@Observable
final class FileMatchCoordinator {

    enum Phase { case idle, indexing, matching, paused, completed, cancelled }

    enum VerifyState {
        case running
        case confirmed(score: Double)
        case conflicted(foundTitle: String)
        case failed(String)
    }

    struct ScoredCandidate: Sendable {
        let filePath: String
        let fileName: String
        let format: String
        let baseScore: Double
        let versionScore: Double
        var combinedScore: Double { baseScore * 0.7 + versionScore * 0.3 }
    }

    // MARK: - Scan state

    var phase: Phase = .idle
    var showPanel: Bool = false

    var indexedCount: Int = 0
    var totalTracks: Int = 0
    var processedTracks: Int = 0
    var confidentCount: Int = 0
    var reviewCount: Int = 0
    var noMatchCount: Int = 0
    var currentTrackLabel: String = ""
    var lastError: String? = nil

    // In-memory candidates for review rows (transient — repopulated each scan run)
    var reviewCandidates: [String: [ScoredCandidate]] = [:]
    var verifyStates: [String: VerifyState] = [:]

    private let context: ModelContext
    private var scanTask: Task<Void, Never>?
    private var pendingLimit: Int? = nil

    nonisolated static let formatPriority: [String: Int] = [
        "flac": 0, "aiff": 1, "wav": 2, "m4a": 3,
        "mp3": 4, "ogg": 5, "opus": 6, "mp4": 7
    ]

    var shouldShowPanel: Bool { phase != .idle }

    init(context: ModelContext) { self.context = context }

    // MARK: - Controls

    func startTestBatch(size: Int = 150) {
        guard phase == .idle || phase == .completed || phase == .cancelled else { return }
        beginScan(limit: size)
    }

    func startFullScan() {
        guard phase == .idle || phase == .completed || phase == .cancelled else { return }
        beginScan(limit: nil)
    }

    func pause() {
        scanTask?.cancel(); scanTask = nil
        phase = .paused
    }

    func resume() {
        guard phase == .paused else { return }
        beginScan(limit: pendingLimit)
    }

    func cancel() {
        scanTask?.cancel(); scanTask = nil
        phase = .cancelled
    }

    func dismissPanel() {
        phase = .idle
        indexedCount = 0; totalTracks = 0; processedTracks = 0
        confidentCount = 0; reviewCount = 0; noMatchCount = 0
        currentTrackLabel = ""; lastError = nil
    }

    // MARK: - Live stats (for Stats card)

    var confidentFileCount: Int {
        (try? context.fetchCount(FetchDescriptor<TrackEntity>(
            predicate: #Predicate { $0.fileMatchState == "confident" }
        ))) ?? 0
    }

    var reviewFileCount: Int {
        (try? context.fetchCount(FetchDescriptor<TrackEntity>(
            predicate: #Predicate { $0.fileMatchState == "review" }
        ))) ?? 0
    }

    var noMatchFileCount: Int {
        (try? context.fetchCount(FetchDescriptor<TrackEntity>(
            predicate: #Predicate { $0.fileMatchState == "noMatch" }
        ))) ?? 0
    }

    var totalTracksWithRecordingMBID: Int {
        (try? context.fetchCount(FetchDescriptor<TrackEntity>(
            predicate: #Predicate { !$0.recordingMBID.isEmpty }
        ))) ?? 0
    }

    // MARK: - Per-row actions

    func confirmMatch(trackMBID: String, filePath: String) {
        linkFile(filePath: filePath, toTrackMBID: trackMBID, score: 1.0, method: "manual")
        reviewCandidates.removeValue(forKey: trackMBID)
        verifyStates.removeValue(forKey: trackMBID)
        try? context.save()
    }

    func unlinkMatch(trackMBID: String) {
        var td = FetchDescriptor<TrackEntity>(predicate: #Predicate { $0.trackMBID == trackMBID })
        td.fetchLimit = 1
        guard let track = try? context.fetch(td).first else { return }
        if let path = track.primaryLocalFilePath {
            var fd = FetchDescriptor<LocalFileEntity>(predicate: #Predicate { $0.filePath == path })
            fd.fetchLimit = 1
            if let file = try? context.fetch(fd).first {
                file.track = nil
                file.matchMethod = "unmatched"
                file.matchScore = nil
            }
        }
        track.fileMatchState = "noMatch"
        track.primaryLocalFilePath = nil
        try? context.save()
    }

    func skipTrack(trackMBID: String) {
        var td = FetchDescriptor<TrackEntity>(predicate: #Predicate { $0.trackMBID == trackMBID })
        td.fetchLimit = 1
        guard let track = try? context.fetch(td).first else { return }
        track.fileMatchState = "skip"
        reviewCandidates.removeValue(forKey: trackMBID)
        verifyStates.removeValue(forKey: trackMBID)
        try? context.save()
    }

    func assignFile(trackMBID: String, url: URL) {
        let path = url.path
        var fd = FetchDescriptor<LocalFileEntity>(predicate: #Predicate { $0.filePath == path })
        fd.fetchLimit = 1
        if (try? context.fetch(fd))?.isEmpty != false {
            let name = url.lastPathComponent
            let ext = url.pathExtension.lowercased()
            let newFile = LocalFileEntity(filePath: path, fileName: name, format: ext, fileSizeBytes: nil)
            context.insert(newFile)
        }
        linkFile(filePath: path, toTrackMBID: trackMBID, score: 1.0, method: "manual")
        reviewCandidates.removeValue(forKey: trackMBID)
        try? context.save()
    }

    func verifyWithFingerprint(trackMBID: String, recordingMBID: String, filePath: String) async {
        verifyStates[trackMBID] = .running
        guard let fpcalcPath = LocalLibraryService.fpcalcPath(),
              let apiKey = KeychainService.shared.load(for: .acoustIDKey),
              !apiKey.isEmpty else {
            verifyStates[trackMBID] = .failed("fpcalc or AcoustID key not configured")
            return
        }
        let client = AcoustIDClient(fpcalcPath: fpcalcPath, apiKey: apiKey)
        do {
            let fp = try await client.fingerprint(filePath: filePath)
            let result = try await client.lookup(fingerprint: fp.fingerprint, duration: fp.duration)
            if result.recordingMBIDs.contains(recordingMBID) {
                verifyStates[trackMBID] = .confirmed(score: result.topScore)
                linkFile(filePath: filePath, toTrackMBID: trackMBID, score: result.topScore, method: "fingerprint")
                reviewCandidates.removeValue(forKey: trackMBID)
                try? context.save()
            } else {
                verifyStates[trackMBID] = .conflicted(foundTitle: result.recordingMBIDs.first ?? "unknown recording")
            }
        } catch {
            verifyStates[trackMBID] = .failed(error.localizedDescription)
        }
    }

    // MARK: - Internal scan driver

    private func beginScan(limit: Int?) {
        pendingLimit = limit
        showPanel = true
        phase = .indexing
        indexedCount = 0; processedTracks = 0; totalTracks = 0
        confidentCount = 0; reviewCount = 0; noMatchCount = 0
        currentTrackLabel = ""; lastError = nil

        scanTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }

            await self.runPhase1()
            if Task.isCancelled { return }

            await MainActor.run { self.phase = .matching }
            await self.runPhase2(limit: limit)
            if Task.isCancelled { return }

            await MainActor.run {
                try? self.context.save()
                self.phase = .completed
            }
        }
    }

    // MARK: - Phase 1: Index files (unchanged)

    private struct FileInfo: Sendable {
        let path: String
        let name: String
        let format: String
        let size: Int?
    }

    private func runPhase1() async {
        guard let url = LocalLibraryService.resolveLibraryBookmark() else { return }

        // Skip if files are already indexed
        let existing: Set<String> = await MainActor.run {
            let all = (try? self.context.fetch(FetchDescriptor<LocalFileEntity>())) ?? []
            return Set(all.map(\.filePath))
        }
        if !existing.isEmpty {
            await MainActor.run { self.indexedCount = existing.count }
            return
        }

        let audioExtensions: Set<String> = ["flac","mp3","aiff","aif","wav","m4a","mp4","ogg","opus"]
        let skipDirs: Set<String> = ["#recycle","@eaDir",".Trashes",".Spotlight-V100"]

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
            if existing.contains(path) { continue }

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

    // MARK: - Phase 2: String-only bulk scoring

    private struct TrackSummary: Sendable {
        let trackMBID: String
        let recordingMBID: String
        let artist: String
        let title: String
    }

    private struct FileSummary: Sendable {
        let filePath: String
        let fileName: String
        let format: String
    }

    private struct TrackResult: Sendable {
        let trackMBID: String
        let tier: MatchTier
        let topCandidate: ScoredCandidate?
        let allCandidates: [ScoredCandidate]
    }

    private enum MatchTier: String, Sendable {
        case confident, review, noMatch
    }

    private func runPhase2(limit: Int?) async {
        // Snapshot all data on main actor
        let (tracks, files): ([TrackSummary], [FileSummary]) = await MainActor.run {
            let allTracks = (try? self.context.fetch(FetchDescriptor<TrackEntity>())) ?? []
            let eligible = allTracks.filter { t in
                !t.recordingMBID.isEmpty &&
                !["confident", "skip"].contains(t.fileMatchState)
            }
            let scoped = limit.map { Array(eligible.prefix($0)) } ?? Array(eligible)

            let tracks = scoped.map { t -> TrackSummary in
                let artist = t.artistCredit.isEmpty
                    ? (t.collectionItem?.basicInformation?.artists.first?.name ?? "")
                    : t.artistCredit
                return TrackSummary(trackMBID: t.trackMBID, recordingMBID: t.recordingMBID,
                                    artist: artist, title: t.title)
            }

            let allFiles = (try? self.context.fetch(FetchDescriptor<LocalFileEntity>())) ?? []
            let files = allFiles.map { f in
                FileSummary(filePath: f.filePath, fileName: f.fileName, format: f.format)
            }
            return (tracks, files)
        }

        if tracks.isEmpty || files.isEmpty { return }

        await MainActor.run { self.totalTracks = tracks.count }

        // Score off the main actor — nonisolated static, cooperative thread pool
        let results = await FileMatchCoordinator._scoreCandidates(
            tracks: tracks,
            files: files,
            onProgress: { [weak self] count, label in
                await MainActor.run {
                    self?.processedTracks = count
                    self?.currentTrackLabel = label
                }
            }
        )

        // Apply results in chunks on main actor
        let chunkSize = 50
        var allTracks: [TrackEntity] = []
        var allFiles: [LocalFileEntity] = []
        await MainActor.run {
            allTracks = (try? self.context.fetch(FetchDescriptor<TrackEntity>())) ?? []
            allFiles  = (try? self.context.fetch(FetchDescriptor<LocalFileEntity>())) ?? []
        }

        var trackDict: [String: TrackEntity] = [:]
        var fileDict: [String: LocalFileEntity] = [:]
        for t in allTracks { trackDict[t.trackMBID] = t }
        for f in allFiles  { fileDict[f.filePath]   = f }

        var offset = 0
        while offset < results.count {
            if Task.isCancelled { break }
            let end = min(offset + chunkSize, results.count)
            let chunk = Array(results[offset..<end])
            offset = end

            await MainActor.run { [weak self] in
                guard let self else { return }
                self.applyChunk(chunk, trackDict: trackDict, fileDict: fileDict)
                try? self.context.save()
            }
        }
    }

    private func applyChunk(
        _ results: [TrackResult],
        trackDict: [String: TrackEntity],
        fileDict: [String: LocalFileEntity]
    ) {
        for result in results {
            guard let track = trackDict[result.trackMBID] else { continue }

            switch result.tier {
            case .confident:
                guard let top = result.topCandidate,
                      let file = fileDict[top.filePath] else {
                    track.fileMatchState = "noMatch"
                    noMatchCount += 1; processedTracks += 1
                    continue
                }
                file.track = track
                file.matchMethod = "string"
                file.matchScore = top.combinedScore
                track.fileMatchState = "confident"
                track.primaryLocalFilePath = top.filePath
                confidentCount += 1

            case .review:
                track.fileMatchState = "review"
                track.primaryLocalFilePath = result.topCandidate?.filePath
                reviewCandidates[result.trackMBID] = result.allCandidates
                reviewCount += 1

            case .noMatch:
                track.fileMatchState = "noMatch"
                noMatchCount += 1
            }
            processedTracks += 1
        }
    }

    // Nonisolated: runs on cooperative thread pool, never touches SwiftData models
    nonisolated private static func _scoreCandidates(
        tracks: [TrackSummary],
        files: [FileSummary],
        onProgress: @Sendable (Int, String) async -> Void
    ) async -> [TrackResult] {

        struct IndexedFile {
            let summary: FileSummary
            let fullTokens: Set<String>
            let baseTokens: Set<String>
            let version: String?
        }

        // Pre-process every file once
        let indexed: [IndexedFile] = files.map { file in
            let stem = URL(fileURLWithPath: file.fileName).deletingPathExtension().lastPathComponent
            let (base, version) = FuzzyMatch.splitVersion(stem)
            let baseTokens = Set(base.split(separator: " ").map(String.init))
            let fullNorm = FuzzyMatch.normalize(stem)
            let fullTokens = Set(fullNorm.split(separator: " ").map(String.init))
            return IndexedFile(summary: file, fullTokens: fullTokens, baseTokens: baseTokens, version: version)
        }

        // Inverted index on all tokens for fast candidate lookup
        var tokenIndex: [String: [IndexedFile]] = [:]
        for file in indexed {
            for token in file.fullTokens where token.count >= 3 {
                tokenIndex[token, default: []].append(file)
            }
        }

        var results: [TrackResult] = []
        results.reserveCapacity(tracks.count)

        for (i, track) in tracks.enumerated() {
            if Task.isCancelled { break }

            // Narrow candidates using full-text token lookup
            let trackFullNorm = FuzzyMatch.normalize("\(track.artist) \(track.title)")
            let queryTokens = Set(trackFullNorm.split(separator: " ").map(String.init)).filter { $0.count >= 3 }

            var seen = Set<String>()
            var candidates: [IndexedFile] = []
            for token in queryTokens {
                for file in tokenIndex[token] ?? [] {
                    if seen.insert(file.summary.filePath).inserted {
                        candidates.append(file)
                    }
                }
            }

            // Version-aware scoring against base tokens only
            let (trackBase, trackVersion) = FuzzyMatch.splitVersion(track.title)
            let artistNorm = FuzzyMatch.normalize(track.artist)
            let combined = artistNorm.isEmpty ? trackBase : "\(artistNorm) \(trackBase)"
            let trackBaseTokens = Set(combined.split(separator: " ").map(String.init))

            let scored: [ScoredCandidate] = candidates.compactMap { file in
                let base = FuzzyMatch.similarity(tokensA: trackBaseTokens, tokensB: file.baseTokens)
                guard base >= 0.5 else { return nil }
                let ver = FuzzyMatch.versionSimilarity(trackVersion, file.version)
                return ScoredCandidate(filePath: file.summary.filePath,
                                       fileName: file.summary.fileName,
                                       format: file.summary.format,
                                       baseScore: base, versionScore: ver)
            }.sorted { lhs, rhs in
                if abs(lhs.combinedScore - rhs.combinedScore) > 0.01 { return lhs.combinedScore > rhs.combinedScore }
                return (formatPriority[lhs.format] ?? 99) < (formatPriority[rhs.format] ?? 99)
            }

            let top = scored.first
            let tier: MatchTier
            if let top, top.baseScore >= 0.85 {
                let versionConflict   = trackVersion != nil && top.versionScore < 0.4
                let versionAmbiguous  = top.versionScore < 0.6
                let ambiguousChoice   = scored.count >= 2 &&
                    (scored[0].combinedScore - scored[1].combinedScore) < 0.1
                tier = (versionConflict || versionAmbiguous || ambiguousChoice) ? .review : .confident
            } else {
                tier = .noMatch
            }

            results.append(TrackResult(
                trackMBID: track.trackMBID,
                tier: tier,
                topCandidate: top,
                allCandidates: Array(scored.prefix(5))
            ))

            if (i + 1) % 20 == 0 {
                await onProgress(i + 1, "\(track.artist) — \(track.title)")
            }
        }

        return results
    }

    // MARK: - SwiftData helpers (all @MainActor)

    private func linkFile(filePath: String, toTrackMBID trackMBID: String, score: Double, method: String) {
        var td = FetchDescriptor<TrackEntity>(predicate: #Predicate { $0.trackMBID == trackMBID })
        td.fetchLimit = 1
        var fd = FetchDescriptor<LocalFileEntity>(predicate: #Predicate { $0.filePath == filePath })
        fd.fetchLimit = 1
        guard let track = try? context.fetch(td).first,
              let file  = try? context.fetch(fd).first else { return }
        file.track = track
        file.matchMethod = method
        file.matchScore = score
        track.fileMatchState = "confident"
        track.primaryLocalFilePath = filePath
    }

    private func updateMatchState(trackMBID: String, state: String) {
        var d = FetchDescriptor<TrackEntity>(predicate: #Predicate { $0.trackMBID == trackMBID })
        d.fetchLimit = 1
        guard let track = try? context.fetch(d).first else { return }
        track.fileMatchState = state
    }
}
