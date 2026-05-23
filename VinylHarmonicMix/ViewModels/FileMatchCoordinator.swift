import Foundation
import SwiftData
import AVFoundation
#if os(macOS)
import AppKit
#endif

// Top-level Sendable value type — must NOT be nested inside the @MainActor class or
// Swift 6 infers its init as @MainActor-isolated, causing a data race when
// _scoreCandidates (nonisolated) constructs instances on the cooperative thread pool.
struct ScoredCandidate: Sendable {
    // nil only for candidates reconstructed from persisted paths at startup (no live scan);
    // always set during an actual scan so applyResults can do O(1) identity-map lookup.
    let fileID: PersistentIdentifier?
    let filePath: String
    let fileName: String
    let format: String
    let artistScore: Double   // fraction of artist tokens found anywhere in gp+parent+filename
    let titleScore: Double    // Jaccard of track base-title vs cleaned filename stem
    let baseScore: Double     // = artistScore * 0.4 + titleScore * 0.6
    let versionScore: Double
    let version: String?
    let durationMs: Int       // file duration in ms; 0 = unknown / not yet read
    let durationScore: Double // step-function on |trackMs−fileMs|; 0.5 when either is unknown
    let combinedScore: Double // = baseScore * 0.7 + versionScore * 0.3

    // nonisolated required: called from _scoreCandidates (nonisolated static).
    // Without this, Swift 6 infers the init as @MainActor-isolated and the call is a data race.
    nonisolated init(fileID: PersistentIdentifier?, filePath: String, fileName: String, format: String,
                     artistScore: Double, titleScore: Double,
                     versionScore: Double, version: String?,
                     durationMs: Int = 0, durationScore: Double = 0.5) {
        self.fileID        = fileID
        self.filePath      = filePath
        self.fileName      = fileName
        self.format        = format
        self.artistScore   = artistScore
        self.titleScore    = titleScore
        self.baseScore     = artistScore * 0.4 + titleScore * 0.6
        self.versionScore  = versionScore
        self.version       = version
        self.durationMs    = durationMs
        self.durationScore = durationScore
        self.combinedScore = self.baseScore * 0.7 + versionScore * 0.3
    }
}

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

    init(context: ModelContext) {
        self.context = context
        // Defer hydration so it doesn't block app startup; runs after first runloop turn.
        Task { @MainActor [weak self] in self?.hydrateReviewCandidatesIfNeeded() }
    }

    // MARK: - Controls

    func startTestBatch(size: Int = 150) {
        guard phase == .idle || phase == .completed || phase == .cancelled else { return }
        beginScan(limit: size)
    }

    func startFullScan() {
        guard phase == .idle || phase == .completed || phase == .cancelled else { return }
        beginScan(limit: nil)
    }

    /// Awaitable full scan for use by SyncOrchestrator.
    /// Runs Phase 1 (incremental file index) then Phase 2 (re-match) and returns when both complete.
    func startAndAwaitFullScan() async {
        guard phase == .idle || phase == .completed || phase == .cancelled else { return }
        pendingLimit = nil
        showPanel = true
        phase = .indexing
        indexedCount = 0; processedTracks = 0; totalTracks = 0
        confidentCount = 0; reviewCount = 0; noMatchCount = 0
        currentTrackLabel = ""; lastError = nil

        await runPhase1()
        if Task.isCancelled { return }
        phase = .matching
        await runPhase2(limit: nil)
        if Task.isCancelled { return }
        try? context.save()
        phase = .completed
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
            let name             = url.lastPathComponent
            let parentFolder     = url.deletingLastPathComponent().lastPathComponent
            let grandparentFolder = url.deletingLastPathComponent()
                                       .deletingLastPathComponent().lastPathComponent
            let ext = url.pathExtension.lowercased()
            let newFile = LocalFileEntity(filePath: path, fileName: name,
                                          parentFolder: parentFolder,
                                          grandparentFolder: grandparentFolder,
                                          format: ext, fileSizeBytes: nil)
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

        // Task inherits @MainActor from call site — all self accesses below are safe.
        scanTask = Task { [weak self] in
            guard let self else { return }
            await self.runPhase1()
            if Task.isCancelled { return }
            self.phase = .matching
            await self.runPhase2(limit: limit)
            if Task.isCancelled { return }
            try? self.context.save()
            self.phase = .completed
        }
    }

    // MARK: - Phase 1: Index local audio files

    private struct FileInfo: Sendable {
        let path: String
        let name: String
        let parentFolder: String      // direct parent folder (album or artist)
        let grandparentFolder: String // one level up — artist folder in nested structures
        let format: String
        let size: Int?
    }

    private func runPhase1() async {
        deduplicateFileIndex()
        repairOrphanedConfidentTracks()   // reset confident tracks whose file link was stolen by a prior run
        backfillFolderNames()             // ensure parentFolder + grandparentFolder set for all rows

        guard let url = LocalLibraryService.resolveLibraryBookmark() else { return }

        let existing: Set<String> = {
            let all = (try? context.fetch(FetchDescriptor<LocalFileEntity>())) ?? []
            return Set(all.map(\.filePath))
        }()
        indexedCount = existing.count

        // Always walk the library so newly added files are picked up.
        // collectAudioFiles skips paths already in `existing`, so this is incremental.
        let filesToInsert = await Task.detached(priority: .userInitiated) {
            FileMatchCoordinator.collectAudioFiles(at: url, skipping: existing)
        }.value

        if !filesToInsert.isEmpty {
            for f in filesToInsert {
                context.insert(LocalFileEntity(filePath: f.path, fileName: f.name,
                                               parentFolder: f.parentFolder,
                                               grandparentFolder: f.grandparentFolder,
                                               format: f.format, fileSizeBytes: f.size))
            }
            indexedCount = existing.count + filesToInsert.count
            try? context.save()
        }

        // Backfill artistFolder AFTER inserting new files so newly indexed rows are covered.
        backfillArtistFoldersIfNeeded()
        await backfillDurationsIfNeeded()  // fill durationMs == 0 rows
    }

    /// Remove duplicate LocalFileEntity rows (same filePath), keeping the matched one when possible.
    private func deduplicateFileIndex() {
        let all = (try? context.fetch(FetchDescriptor<LocalFileEntity>())) ?? []
        var seen: [String: LocalFileEntity] = [:]
        var toDelete: [LocalFileEntity] = []
        for file in all {
            if let kept = seen[file.filePath] {
                // Prefer the row that already has a track association
                if file.track != nil && kept.track == nil {
                    toDelete.append(kept)
                    seen[file.filePath] = file
                } else {
                    toDelete.append(file)
                }
            } else {
                seen[file.filePath] = file
            }
        }
        guard !toDelete.isEmpty else { return }
        toDelete.forEach { context.delete($0) }
        try? context.save()
        print("[DEDUP] Removed \(toDelete.count) duplicate LocalFileEntity rows; kept \(seen.count)")
    }

    /// Backfill parentFolder and grandparentFolder for rows where either is missing.
    /// Derives both from the stored filePath — no disk re-scan needed.
    private func backfillFolderNames() {
        let all = (try? context.fetch(FetchDescriptor<LocalFileEntity>())) ?? []
        let needs = all.filter { $0.parentFolder.isEmpty || $0.grandparentFolder.isEmpty }
        guard !needs.isEmpty else { return }
        for file in needs {
            let url = URL(fileURLWithPath: file.filePath)
            let parent      = url.deletingLastPathComponent().lastPathComponent
            let grandparent = url.deletingLastPathComponent()
                                 .deletingLastPathComponent().lastPathComponent
            if file.parentFolder.isEmpty      { file.parentFolder      = parent }
            if file.grandparentFolder.isEmpty { file.grandparentFolder = grandparent }
        }
        try? context.save()
        print("[BACKFILL] Set folder names on \(needs.count) rows")
    }

    /// Resets any confident track whose file link is stale — either because the file no longer
    /// exists in LocalFileEntity, or because a subsequent scan re-linked it to a different track.
    /// Uses an explicit path-ownership map rather than SwiftData's `localFiles` inverse
    /// (which can return a stale cached view when the FK was changed without clearing the cache).
    private func repairOrphanedConfidentTracks() {
        let confident = (try? context.fetch(FetchDescriptor<TrackEntity>(
            predicate: #Predicate { $0.fileMatchState == "confident" }
        ))) ?? []
        guard !confident.isEmpty else { return }

        // Build filePath → actual owning track PK from the FK column (lf.ZTRACK / lf.track).
        // This is authoritative — it's what the DB actually stores, not what the object cache thinks.
        let allFiles = (try? context.fetch(FetchDescriptor<LocalFileEntity>())) ?? []
        var actualOwner: [String: PersistentIdentifier] = [:]
        for f in allFiles {
            if let t = f.track { actualOwner[f.filePath] = t.persistentModelID }
        }

        var repaired = 0
        for track in confident {
            let isOrphan: Bool
            if let path = track.primaryLocalFilePath {
                // Orphaned if the file row doesn't exist, or if its .track FK points elsewhere.
                isOrphan = actualOwner[path] != track.persistentModelID
            } else {
                isOrphan = true   // confident with no path at all
            }
            if isOrphan {
                track.fileMatchState = "unscanned"
                track.primaryLocalFilePath = nil
                repaired += 1
            }
        }
        guard repaired > 0 else { return }
        try? context.save()
        print("[REPAIR] Reset \(repaired) orphaned confident tracks to unscanned")
    }

    /// Returns the first path component after "Tracks/" in filePath, or "" if not found.
    /// Pure string operation — no disk I/O.
    nonisolated static func extractArtistFolder(from filePath: String) -> String {
        let components = filePath.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let idx = components.firstIndex(where: { $0.caseInsensitiveCompare("Tracks") == .orderedSame }),
              idx + 1 < components.count else { return "" }
        return components[idx + 1]
    }

    /// Backfill artistFolder for any LocalFileEntity where it is still empty.
    /// Path-only parsing — does NOT re-read file durations or access disk.
    private func backfillArtistFoldersIfNeeded() {
        let needs = ((try? context.fetch(FetchDescriptor<LocalFileEntity>())) ?? [])
            .filter { $0.artistFolder.isEmpty }
        guard !needs.isEmpty else { return }
        for file in needs {
            file.artistFolder = FileMatchCoordinator.extractArtistFolder(from: file.filePath)
        }
        try? context.save()
        print("[BACKFILL] Set artistFolder on \(needs.count) rows")
    }

    /// Reads AVAsset duration for every LocalFileEntity that still has durationMs == 0.
    /// First call after the app update processes all existing rows; subsequent calls are near-instant
    /// because only genuinely unreadable files remain at 0.
    private func backfillDurationsIfNeeded() async {
        let needsDuration = (try? context.fetch(FetchDescriptor<LocalFileEntity>(
            predicate: #Predicate { $0.durationMs == 0 }
        ))) ?? []
        guard !needsDuration.isEmpty else { return }
        print("[DURATION] Backfilling durations for \(needsDuration.count) files…")

        struct Stub: Sendable { let id: PersistentIdentifier; let path: String }
        let stubs = needsDuration.map { Stub(id: $0.persistentModelID, path: $0.filePath) }

        let chunkSize = 100
        var filled = 0
        for offset in stride(from: 0, to: stubs.count, by: chunkSize) {
            if Task.isCancelled { break }
            let chunk = Array(stubs[offset ..< min(offset + chunkSize, stubs.count)])
            currentTrackLabel = "Reading durations… (\(offset)/\(stubs.count))"

            // Parallel AVAsset header reads — each task creates + discards its own asset instance.
            let pairs: [(PersistentIdentifier, Int)] = await withTaskGroup(
                of: (PersistentIdentifier, Int).self
            ) { group in
                for stub in chunk {
                    let path = stub.path
                    let id   = stub.id
                    group.addTask {
                        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
                        let cm    = try? await asset.load(.duration)
                        let ms    = cm.map { Int(CMTimeGetSeconds($0) * 1000) } ?? 0
                        return (id, ms)
                    }
                }
                var out: [(PersistentIdentifier, Int)] = []
                for await pair in group { out.append(pair) }
                return out
            }

            for (id, ms) in pairs {
                if let file = context.model(for: id) as? LocalFileEntity {
                    file.durationMs = ms > 0 ? ms : -1  // -1 = tried, permanently unreadable
                }
            }
            filled += pairs.filter { $0.1 > 0 }.count
            try? context.save()
            await Task.yield()
        }
        print("[DURATION] Backfill complete: \(filled)/\(stubs.count) durations read")
    }

    /// Synchronous directory walk — no actor state, safe for Task.detached.
    nonisolated private static func collectAudioFiles(at url: URL,
                                                       skipping existing: Set<String>) -> [FileInfo] {
        let audioExts: Set<String> = ["flac","mp3","aiff","aif","wav","m4a","mp4","ogg","opus"]
        let skipDirs: Set<String>  = ["#recycle","@eaDir",".Trashes",".Spotlight-V100"]

        guard let enumerator = FileManager().enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var files: [FileInfo] = []
        // Use nextObject() — for-in over NSDirectoryEnumerator is unavailable in async contexts.
        while let obj = enumerator.nextObject() {
            guard let fileURL = obj as? URL else { continue }
            let name = fileURL.lastPathComponent
            if skipDirs.contains(name) { enumerator.skipDescendants(); continue }
            let ext = fileURL.pathExtension.lowercased()
            guard audioExts.contains(ext) else { continue }
            let path = fileURL.path
            if existing.contains(path) { continue }
            let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize
            let parentFolder      = fileURL.deletingLastPathComponent().lastPathComponent
            let grandparentFolder = fileURL.deletingLastPathComponent()
                                           .deletingLastPathComponent().lastPathComponent
            files.append(FileInfo(path: path, name: name,
                                  parentFolder: parentFolder, grandparentFolder: grandparentFolder,
                                  format: ext, size: size))
        }
        return files
    }

    // MARK: - Phase 2: String-only bulk scoring

    private struct TrackSummary: Sendable {
        let id: PersistentIdentifier   // for context.model(for:) in write-back — no dict re-fetch
        let trackMBID: String
        let recordingMBID: String
        let artist: String
        let title: String
        let durationMs: Int  // 0 = unknown (TrackEntity.durationMs is Int?)
    }

    private struct FileSummary: Sendable {
        let id: PersistentIdentifier   // for context.model(for:) in write-back — no predicate fetch
        let filePath: String
        let fileName: String
        let parentFolder: String
        let grandparentFolder: String
        let format: String
        let durationMs: Int  // 0 = not yet backfilled or AVAsset failed
        let artistFolder: String     // first path component under "Tracks/" root
    }

    // MatchResult carries PersistentIdentifiers so write-back never touches the context
    // off the main actor — identifiers are Sendable value types.
    private struct MatchResult: Sendable {
        let trackID: PersistentIdentifier  // → context.model(for:) in applyResults
        let trackMBID: String              // → reviewCandidates dict key (UI state)
        let tier: MatchTier
        let topCandidate: ScoredCandidate?
        let allCandidates: [ScoredCandidate]
    }

    private enum MatchTier: String, Sendable {
        case confident, review, noMatch
    }

    private func runPhase2(limit: Int?) async {
        // ── Snapshot: extract Sendable value types from SwiftData models ──────────────
        // All model access happens HERE on the MainActor. The scoring step below is
        // nonisolated and must never touch the context or any @Model object.
        let allTracksFromDB = (try? context.fetch(FetchDescriptor<TrackEntity>())) ?? []
        let eligible = allTracksFromDB.filter { t in
            !t.recordingMBID.isEmpty && !["confident", "skip"].contains(t.fileMatchState)
        }
        let scoped = limit.map { Array(eligible.prefix($0)) } ?? Array(eligible)

        let tracks: [TrackSummary] = scoped.map { t -> TrackSummary in
            let artist = t.artistCredit.isEmpty
                ? (t.collectionItem?.basicInformation?.artists.first?.name ?? "")
                : t.artistCredit
            // persistentModelID is Sendable — safe to pass to nonisolated scoring
            return TrackSummary(id: t.persistentModelID,
                                trackMBID: t.trackMBID, recordingMBID: t.recordingMBID,
                                artist: artist, title: t.title,
                                durationMs: t.durationMs ?? 0)
        }

        // Load files into the context's identity map so context.model(for:) in
        // applyResults is O(1) — no predicate fetch needed at write-back time.
        let allFiles = (try? context.fetch(FetchDescriptor<LocalFileEntity>())) ?? []
        let files: [FileSummary] = allFiles.map { f in
            FileSummary(id: f.persistentModelID,
                        filePath: f.filePath, fileName: f.fileName,
                        parentFolder: f.parentFolder, grandparentFolder: f.grandparentFolder,
                        format: f.format, durationMs: f.durationMs,
                        artistFolder: f.artistFolder)
        }

        if tracks.isEmpty || files.isEmpty { return }
        totalTracks = tracks.count

        // Paths already claimed by confident/skip tracks that are NOT being re-scored this run.
        // Passed to the conflict dedup so review-state tracks can't silently steal these files.
        let lockedPaths: Set<String> = Set(
            allTracksFromDB
                .filter { ["confident", "skip"].contains($0.fileMatchState) }
                .compactMap { $0.primaryLocalFilePath }
        )

        // ── Scoring (nonisolated, cooperative thread pool) ────────────────────────────
        // progressCallback hops back to MainActor via MainActor.run; it ONLY touches
        // simple stored properties, never the ModelContext.
        let progressCallback: @Sendable (Int, String) async -> Void = { [weak self] count, label in
            await MainActor.run { [weak self] in
                self?.processedTracks = count
                self?.currentTrackLabel = label
            }
        }
        let results = await FileMatchCoordinator._scoreCandidates(
            tracks: tracks,
            files: files,
            lockedPaths: lockedPaths,
            onProgress: progressCallback
        )

        // ── Write-back (MainActor, chunked) ───────────────────────────────────────────
        // applyResults uses context.model(for:) — O(1) identity map lookup for both
        // TrackEntity and LocalFileEntity. No dict build, no predicate fetches.
        await applyResults(results)
    }

    // All SwiftData writes happen here, on the MainActor, in 25-item chunks.
    // context.model(for:) resolves PersistentIdentifiers via the identity map — O(1),
    // no predicate scanning. Task.yield() after each chunk keeps the UI responsive.
    @MainActor
    private func applyResults(_ results: [MatchResult]) async {
        let chunkSize = 25
        for offset in stride(from: 0, to: results.count, by: chunkSize) {
            if Task.isCancelled { break }
            let end = min(offset + chunkSize, results.count)

            for result in results[offset..<end] {
                guard let track = context.model(for: result.trackID) as? TrackEntity else { continue }

                switch result.tier {
                case .confident:
                    guard let top = result.topCandidate else {
                        track.fileMatchState = "noMatch"; noMatchCount += 1; continue
                    }
                    // Try O(1) identity-map lookup first; fall back to predicate fetch when the
                    // object was evicted from the in-memory cache (rare but causes orphaned confident
                    // tracks where primaryLocalFilePath is set but lf.ZTRACK is null).
                    var file = top.fileID.flatMap { context.model(for: $0) as? LocalFileEntity }
                    if file == nil {
                        let filePath = top.filePath
                        var fd = FetchDescriptor<LocalFileEntity>(predicate: #Predicate { $0.filePath == filePath })
                        fd.fetchLimit = 1
                        file = try? context.fetch(fd).first
                    }
                    guard let file else {
                        // File was deleted or otherwise unresolvable — don't create an orphan.
                        track.fileMatchState = "noMatch"; noMatchCount += 1; continue
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
                    // Persist paths so candidates survive app restart without re-scanning.
                    track.candidateFilePaths = result.allCandidates.map(\.filePath)
                    reviewCount += 1

                case .noMatch:
                    track.fileMatchState = "noMatch"
                    noMatchCount += 1
                }
            }

            try? context.save()
            await Task.yield()
        }
    }

    // Nonisolated: runs on the cooperative thread pool.
    // Contract: NEVER touches self.context or any @Model object.
    // Only operates on Sendable value-type snapshots (TrackSummary, FileSummary, PersistentIdentifier).
    nonisolated private static func _scoreCandidates(
        tracks: [TrackSummary],
        files: [FileSummary],
        lockedPaths: Set<String>,
        onProgress: @Sendable (Int, String) async -> Void
    ) async -> [MatchResult] {

        struct IndexedFile {
            let summary: FileSummary
            let stemTokens: Set<String>
            let version: String?
        }

        // Pre-process every file once — stem tokens from filename only
        let indexed: [IndexedFile] = files.map { file in
            var stem = URL(fileURLWithPath: file.fileName).deletingPathExtension().lastPathComponent
            stem = stem.replacingOccurrences(of: #"^\d{1,3}[\s\.\-_]+"#, with: "", options: .regularExpression)
            // Strip "Artist - Title" / "Artist – Title" naming convention prefix so the
            // artist name doesn't dilute the title's Jaccard score (e.g. "49ers – Die Walküre").
            if let dashRange = stem.range(of: " - ") ?? stem.range(of: " \u{2013} ") {
                let rest = String(stem[dashRange.upperBound...]).trimmingCharacters(in: .whitespaces)
                if !rest.isEmpty { stem = rest }
            }
            let (base, version) = FuzzyMatch.splitVersion(stem)
            let stemTokens = Set(base.split(separator: " ").map(String.init))
            return IndexedFile(summary: file, stemTokens: stemTokens, version: version)
        }

        // Build per-folder index keyed by artistFolder
        var folderIndex: [String: [IndexedFile]] = [:]
        for file in indexed where !file.summary.artistFolder.isEmpty {
            folderIndex[file.summary.artistFolder, default: []].append(file)
        }

        // Pre-compute normalised tokens for each folder name once
        struct FolderEntry { let name: String; let tokens: Set<String> }
        let folderEntries: [FolderEntry] = folderIndex.keys.map { name in
            let norm   = FuzzyMatch.normalizeFolderName(name)
            let tokens = Set(norm.split(separator: " ").map(String.init)).filter { $0.count >= 2 }
            return FolderEntry(name: name, tokens: tokens)
        }

        var results: [MatchResult] = []
        results.reserveCapacity(tracks.count)

        for (i, track) in tracks.enumerated() {
            if Task.isCancelled { break }

            // Stage 1: artist-folder hard filter
            // Splits collaboration artists ("D-Mob & Cathy Dennis" → ["D-Mob", "Cathy Dennis"])
            // and scores each sub-artist against each folder using bidirectional max denominator:
            //   shared / max(folderTokens, subArtistTokens)
            // This prevents single-token coincidences from matching (e.g. "people" in "M People"
            // folder matching "Aquatic People" artist — 1/max(1,2)=0.5, below threshold).
            var artistSubTokenSets: [Set<String>] = []
            var remainingArtist = track.artist
            for delim in [" & ", " feat. ", " feat ", " featuring ", " vs. ", " vs ", ", "] {
                remainingArtist = remainingArtist.replacingOccurrences(of: delim, with: "|||",
                                                                       options: .caseInsensitive)
            }
            for part in remainingArtist.components(separatedBy: "|||") {
                let norm   = FuzzyMatch.normalize(part.trimmingCharacters(in: .whitespaces))
                let tokens = Set(norm.split(separator: " ").map(String.init)).filter { $0.count >= 2 }
                if !tokens.isEmpty { artistSubTokenSets.append(tokens) }
            }

            var bestFolderScore = 0.0
            var bestFolderName  = ""
            var matchedFiles: [IndexedFile] = []

            for entry in folderEntries {
                guard !entry.tokens.isEmpty else { continue }
                var bestSubScore = 0.0
                for subTokens in artistSubTokenSets {
                    let hit   = Double(subTokens.intersection(entry.tokens).count)
                    let score = hit / Double(max(entry.tokens.count, subTokens.count))
                    if score > bestSubScore { bestSubScore = score }
                }
                if bestSubScore >= 0.7 {
                    matchedFiles += folderIndex[entry.name] ?? []
                    if bestSubScore > bestFolderScore { bestFolderScore = bestSubScore; bestFolderName = entry.name }
                }
            }

            guard !matchedFiles.isEmpty else {
                if i < 20 {
                    print("[MATCH \(i+1)] \(track.artist) – \(track.title)  [NO FOLDER MATCH]")
                    print("  artistSubTokens=\(artistSubTokenSets.map { $0.sorted() })")
                }
                results.append(MatchResult(trackID: track.id, trackMBID: track.trackMBID,
                                           tier: .noMatch, topCandidate: nil, allCandidates: []))
                if (i + 1) % 20 == 0 { await onProgress(i + 1, "\(track.artist) \u{2013} \(track.title)") }
                continue
            }

            // Stage 2: title / version / duration within matched folders
            let (trackBase, trackVersion) = FuzzyMatch.splitVersion(track.title)
            let trackTitleTokens = Set(trackBase.split(separator: " ").map(String.init))

            let scored: [ScoredCandidate] = matchedFiles.compactMap { file -> ScoredCandidate? in
                let titleScore = FuzzyMatch.similarity(tokensA: trackTitleTokens, tokensB: file.stemTokens)
                guard titleScore >= 0.2 else { return nil }

                let ver = FuzzyMatch.versionSimilarity(trackVersion, file.version)

                let trackMs = track.durationMs
                let fileMs  = file.summary.durationMs
                let durScore: Double
                if trackMs == 0 || fileMs <= 0 {  // 0 = unknown, -1 = read failed
                    durScore = 0.5
                } else {
                    let diffSec = abs(trackMs - fileMs) / 1000
                    switch diffSec {
                    case 0...5:   durScore = 1.0
                    case 6...15:  durScore = 0.8
                    case 16...30: durScore = 0.5
                    default:      durScore = 0.2
                    }
                }

                return ScoredCandidate(fileID: file.summary.id,
                                       filePath: file.summary.filePath,
                                       fileName: file.summary.fileName,
                                       format: file.summary.format,
                                       artistScore: bestFolderScore,
                                       titleScore: titleScore,
                                       versionScore: ver,
                                       version: file.version,
                                       durationMs: fileMs,
                                       durationScore: durScore)
            }.sorted { lhs, rhs in
                if abs(lhs.combinedScore - rhs.combinedScore) > 0.01 { return lhs.combinedScore > rhs.combinedScore }
                if abs(lhs.durationScore - rhs.durationScore) > 0.05 { return lhs.durationScore > rhs.durationScore }
                return (formatPriority[lhs.format] ?? 99) < (formatPriority[rhs.format] ?? 99)
            }

            let top = scored.first
            let tier: MatchTier
            if let top {
                // Artist is already guaranteed by folder match — only title + version determine tier.
                // Duration is a sort-order tiebreaker only; it never blocks a confident match.
                let titleOK = top.titleScore >= 0.8
                let verOK   = trackVersion == nil || top.versionScore >= 0.6
                tier = (titleOK && verOK) ? .confident : .review
            } else {
                tier = .noMatch
            }

            // Debug: first 20 tracks
            if i < 20 {
                let f2: (Double) -> String = { String(format: "%.2f", $0) }
                let mmss: (Int) -> String = { ms in
                    ms > 0 ? "\(ms/60000):\(String(format: "%02d", (ms%60000)/1000))" : "?"
                }
                let titStr  = top.map { f2($0.titleScore)    } ?? "—"
                let verStr  = top.map { f2($0.versionScore)  } ?? "—"
                let durStr  = top.map { f2($0.durationScore) } ?? "—"
                let durInfo = top.map { "\(mmss(track.durationMs)) / \(mmss($0.durationMs))" } ?? "—"
                print("[MATCH \(i+1)] \(track.artist) – \(track.title)  [folder=\(matchedFiles.count) scored=\(scored.count)]")
                print("  artistFolder='\(bestFolderName)' | artistFolderScore=\(f2(bestFolderScore)) | title=\(titStr) | ver=\(verStr) | dur=\(durStr) (\(durInfo)) | tier=\(tier)")
            }

            results.append(MatchResult(
                trackID: track.id,
                trackMBID: track.trackMBID,
                tier: tier,
                topCandidate: top,
                allCandidates: Array(scored.prefix(5))
            ))

            if (i + 1) % 20 == 0 {
                await onProgress(i + 1, "\(track.artist) \u{2013} \(track.title)")
            }
        }

        // Conflict dedup: one physical file → at most one confident match.
        // When two tracks both scored the same file as their best confident candidate,
        // keep the higher combinedScore as confident and downgrade the other to review.
        // Without this, multi-version releases (e.g. 5 "Voo-Doo Believe?" variants) all
        // become confident on the one file that exists, producing bogus results.
        //
        // index = -1 is a sentinel for paths locked by already-confident tracks that were
        // skipped this run. Nothing in `results` can beat them (score = .infinity).
        var bestConfidentByPath: [String: (index: Int, score: Double)] = [:]
        for path in lockedPaths {
            bestConfidentByPath[path] = (index: -1, score: .infinity)
        }
        for (i, result) in results.enumerated() {
            guard result.tier == .confident, let top = result.topCandidate else { continue }
            let path = top.filePath
            if let existing = bestConfidentByPath[path] {
                // Locked paths (index == -1) can never be beaten — downgrade to review.
                let canBeat = existing.index >= 0 && top.combinedScore > existing.score
                if canBeat {
                    let old = results[existing.index]
                    results[existing.index] = MatchResult(trackID: old.trackID,
                                                          trackMBID: old.trackMBID,
                                                          tier: .review,
                                                          topCandidate: old.topCandidate,
                                                          allCandidates: old.allCandidates)
                    bestConfidentByPath[path] = (i, top.combinedScore)
                } else {
                    results[i] = MatchResult(trackID: result.trackID,
                                             trackMBID: result.trackMBID,
                                             tier: .review,
                                             topCandidate: result.topCandidate,
                                             allCandidates: result.allCandidates)
                }
            } else {
                bestConfidentByPath[path] = (i, top.combinedScore)
            }
        }

        // Final flush so processedTracks == totalTracks before applyChunk runs.
        // Prevents ProgressView out-of-bounds when applyChunk would otherwise push it past 1.0.
        await onProgress(tracks.count, "Applying…")

        return results
    }

    // MARK: - Candidate hydration

    // Rebuilds reviewCandidates from persisted TrackEntity.candidateFilePaths so
    // review rows show their best guess after app restart without re-scanning.
    // Called once at startup (deferred via Task so it doesn't block init).
    func hydrateReviewCandidatesIfNeeded() {
        let reviewTracks = (try? context.fetch(FetchDescriptor<TrackEntity>(
            predicate: #Predicate { $0.fileMatchState == "review" }
        ))) ?? []
        guard reviewTracks.contains(where: { !$0.candidateFilePaths.isEmpty }) else { return }

        // Bulk load all files into the context's identity map — O(N) once at startup;
        // objects become available for O(1) context.model(for:) later.
        let allFiles = (try? context.fetch(FetchDescriptor<LocalFileEntity>())) ?? []
        var fileByPath: [String: LocalFileEntity] = [:]
        fileByPath.reserveCapacity(allFiles.count)
        for f in allFiles { fileByPath[f.filePath] = f }

        for track in reviewTracks where reviewCandidates[track.trackMBID] == nil {
            let candidates: [ScoredCandidate] = track.candidateFilePaths.compactMap { path in
                guard let file = fileByPath[path] else { return nil }
                // baseScore=0 signals "loaded from disk, no live score available";
                // the UI hides the score line when baseScore == 0.
                // artistScore=0 / titleScore=0 signals "loaded from disk, no live scores".
                // The UI hides numeric score display when baseScore (= 0) is zero.
                return ScoredCandidate(fileID: file.persistentModelID,
                                       filePath: path,
                                       fileName: file.fileName,
                                       format: file.format,
                                       artistScore: 0, titleScore: 0,
                                       versionScore: 0.5, version: nil)
            }
            if !candidates.isEmpty {
                reviewCandidates[track.trackMBID] = candidates
            }
        }
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
