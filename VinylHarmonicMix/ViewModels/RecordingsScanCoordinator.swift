import Foundation
import SwiftData

@MainActor
@Observable
final class RecordingsScanCoordinator {

    enum Phase {
        case idle
        case scanning
        case paused
        case completed
        case cancelled
        case failed(String)
    }

    struct ScanningItemInfo {
        let title: String
        let artist: String
    }

    struct FailedRecordingInfo: Identifiable {
        let instanceId: Int
        let title: String
        let artist: String
        var id: Int { instanceId }
    }

    var phase: Phase = .idle
    var passProcessed: Int = 0
    var passTotal: Int = 0
    var currentItem: ScanningItemInfo? = nil
    var showBanner: Bool = false

    private let context: ModelContext
    private let client = MusicBrainzClient()
    private var scanTask: Task<Void, Never>?
    private var processedCount: Int = 0

    init(context: ModelContext) {
        self.context = context
    }

    // MARK: - Live counts

    private func fetchCount(state: RecordingsScanState) -> Int {
        let raw = state.rawValue
        let d = FetchDescriptor<CollectionItemEntity>(
            predicate: #Predicate { $0.recordingsScanState == raw }
        )
        return (try? context.fetchCount(d)) ?? 0
    }

    var fetchedCount: Int   { fetchCount(state: .fetched) }
    var failedCount: Int    { fetchCount(state: .failed) }
    var skippedCount: Int   { fetchCount(state: .skipped) }

    var unscannedWithMBIDCount: Int {
        let raw = RecordingsScanState.unscanned.rawValue
        let d = FetchDescriptor<CollectionItemEntity>(
            predicate: #Predicate { $0.recordingsScanState == raw }
        )
        return ((try? context.fetch(d)) ?? []).filter { $0.mbid != nil }.count
    }

    var totalTrackCount: Int {
        (try? context.fetchCount(FetchDescriptor<TrackEntity>())) ?? 0
    }

    var failedRecordings: [FailedRecordingInfo] {
        let raw = RecordingsScanState.failed.rawValue
        let d = FetchDescriptor<CollectionItemEntity>(
            predicate: #Predicate { $0.recordingsScanState == raw }
        )
        return ((try? context.fetch(d)) ?? []).map { entity in
            FailedRecordingInfo(
                instanceId: entity.instanceId,
                title: entity.basicInformation?.title ?? "Unknown",
                artist: entity.basicInformation?.artists.map(\.name).joined(separator: " & ") ?? ""
            )
        }
    }

    var shouldShowPanel: Bool {
        switch phase {
        case .scanning, .paused, .completed, .cancelled, .failed: return true
        case .idle: return false
        }
    }

    var estimatedRemainingMinutes: Int {
        guard case .scanning = phase, passProcessed > 0, passTotal > 0 else { return 0 }
        let remaining = max(0, passTotal - passProcessed)
        let seconds = Double(remaining) * 1.05
        return Int(ceil(seconds / 60.0))
    }

    // MARK: - Controls

    func start() {
        switch phase {
        case .idle, .completed, .cancelled: break
        default: return
        }
        processedCount = 0
        passProcessed = 0
        startScanInternal()
    }

    private func startScanInternal() {
        phase = .scanning
        showBanner = true

        // Mark items without MBID as skipped, synthesize orphan TrackEntity rows
        let rawUnscanned = RecordingsScanState.unscanned.rawValue
        let noMBIDCandidates = (try? context.fetch(FetchDescriptor<CollectionItemEntity>(
            predicate: #Predicate { $0.recordingsScanState == rawUnscanned }
        )))?.filter { $0.mbid == nil } ?? []
        markSkippedAndSynthesize(noMBIDCandidates)

        let rawFailed = RecordingsScanState.failed.rawValue
        let remaining = (try? context.fetchCount(FetchDescriptor<CollectionItemEntity>(
            predicate: #Predicate { $0.recordingsScanState == rawUnscanned || $0.recordingsScanState == rawFailed }
        ))) ?? 0
        passTotal = processedCount + remaining

        scanTask = Task { await performScan() }
    }

    private func performScan() async {
        let rawUnscanned = RecordingsScanState.unscanned.rawValue
        let rawFailed    = RecordingsScanState.failed.rawValue
        let descriptor = FetchDescriptor<CollectionItemEntity>(
            predicate: #Predicate { $0.recordingsScanState == rawUnscanned || $0.recordingsScanState == rawFailed }
        )
        let queue: [CollectionItemEntity]
        do {
            queue = try context.fetch(descriptor)
        } catch {
            phase = .failed("Database fetch failed: \(error.localizedDescription)")
            return
        }

        let mbidQueue = queue.filter { $0.mbid != nil }
        let skippable = queue.filter { $0.mbid == nil }
        markSkippedAndSynthesize(skippable)

        print("🎵 Recordings scan: \(mbidQueue.count) items with MBID to process")

        await processItems(mbidQueue)
        phase = .completed
    }

    // Core fetch-and-insert loop shared by batch scan and startForSingle.
    private func processItems(_ items: [CollectionItemEntity]) async {
        var saveCounter = 0
        for entity in items {
            if Task.isCancelled {
                currentItem = nil
                try? context.save()
                return
            }

            currentItem = ScanningItemInfo(
                title: entity.basicInformation?.title ?? "—",
                artist: entity.basicInformation?.artists.first?.name ?? "Unknown artist"
            )

            do {
                let recordings = try await client.fetchRecordings(forReleaseMBID: entity.mbid!)

                // Delete stale tracks before inserting fresh ones
                let existingTracks = entity.tracks
                for track in existingTracks { context.delete(track) }

                for match in recordings {
                    let track = TrackEntity(
                        trackMBID: match.trackMBID,
                        recordingMBID: match.recordingMBID,
                        position: match.position,
                        title: match.title,
                        durationMs: match.durationMs,
                        artistCredit: match.artistCredit
                    )
                    track.collectionItem = entity
                    context.insert(track)
                }
                entity.recordingsScanState = RecordingsScanState.fetched.rawValue
                entity.recordingsScannedAt = Date()
            } catch is CancellationError {
                print("⏸️ Recordings scan cancelled mid-request for \(entity.mbid ?? "?")")
                try? context.save()
                currentItem = nil
                return
            } catch {
                entity.recordingsScanState = RecordingsScanState.failed.rawValue
                entity.recordingsScannedAt = Date()
                print("⚠️ Recordings fetch failed for \(entity.mbid ?? "?"): \(error)")
            }

            processedCount += 1
            passProcessed = processedCount
            saveCounter += 1

            if saveCounter >= 10 {
                do { try context.save() } catch { print("❌ Batch save: \(error)") }
                saveCounter = 0
            }
        }

        do { try context.save() } catch { print("❌ Final save: \(error)") }
        currentItem = nil
    }

    // Fetch recordings for a single release and create its TrackEntity rows.
    // Refuses to run if a batch scan is already in progress.
    func startForSingle(_ entity: CollectionItemEntity) async {
        switch phase {
        case .scanning, .paused: return
        default: break
        }
        guard entity.mbid != nil else {
            // No MusicBrainz binding — Discogs is the source of truth for track lists.
            // Idempotent no-op if the release already has tracks (real or synthesized).
            if synthesizeTracksForOrphanRelease(entity) > 0 {
                try? context.save()
            }
            return
        }
        processedCount = 0
        passProcessed = 0
        passTotal = 1
        phase = .scanning
        showBanner = true
        await processItems([entity])
        phase = .completed
    }

    func resume() {
        guard case .paused = phase else { return }
        startScanInternal()
    }

    func pause() {
        phase = .paused
        scanTask?.cancel()
        scanTask = nil
    }

    func cancel() {
        scanTask?.cancel()
        scanTask = nil
        currentItem = nil
        phase = .cancelled
    }

    func dismissPanel() {
        phase = .idle
        passProcessed = 0
        passTotal = 0
        processedCount = 0
        showBanner = false
    }

    func resetToUnscanned(instanceId: Int) {
        let id = instanceId
        var descriptor = FetchDescriptor<CollectionItemEntity>(
            predicate: #Predicate { $0.instanceId == id }
        )
        descriptor.fetchLimit = 1
        guard let entity = try? context.fetch(descriptor).first else { return }
        entity.recordingsScanState = RecordingsScanState.unscanned.rawValue
        entity.recordingsScannedAt = nil
        try? context.save()
    }

    // MARK: - Orphan release synthesis

    /// Marks each item as .skipped and synthesizes TrackEntity rows from its Discogs
    /// tracklist. One save at the end — callers must not save separately.
    private func markSkippedAndSynthesize(_ items: [CollectionItemEntity]) {
        guard !items.isEmpty else { return }
        for item in items {
            item.recordingsScanState = RecordingsScanState.skipped.rawValue
            synthesizeTracksForOrphanRelease(item)
        }
        try? context.save()
    }

    /// Back-fills synthetic TrackEntity rows for any release already in the database
    /// that doesn't yet have tracks — with or without an MBID. Discogs is the source of
    /// truth for track lists. Safe to call on every launch — idempotent (skips any
    /// release whose tracks array is already non-empty, MusicBrainz-fetched or not).
    func backfillOrphanReleaseTracks() {
        let all = (try? context.fetch(FetchDescriptor<CollectionItemEntity>())) ?? []
        let trackless = all.filter { $0.tracks.isEmpty }
        guard !trackless.isEmpty else { return }
        var totalCreated = 0
        for entity in trackless {
            totalCreated += synthesizeTracksForOrphanRelease(entity)
        }
        if totalCreated > 0 { try? context.save() }
    }

    /// Synthesize TrackEntity rows for a release with no TrackEntity rows yet, regardless
    /// of whether it has a MusicBrainz release MBID — Discogs is the source of truth for
    /// track lists. Each synthesized track gets trackMBID = "discogs:{releaseId}:{position}"
    /// (unique, stable, visually distinct from real MB UUIDs), recordingMBID = "" (empty,
    /// signals "no MB binding"), and fileMatchState = "unscanned" (so the UI shows the
    /// "Set file" button).
    ///
    /// Idempotent, and safe for the hard constraint of never touching a release that
    /// already has tracks: guarded by `entity.tracks.isEmpty`, so a release with real
    /// MusicBrainz-fetched tracks (or previously-synthesized ones) is always a no-op here,
    /// regardless of MBID. Also skips any individual surrogate position that already exists.
    ///
    /// Returns the number of new TrackEntity rows created.
    @discardableResult
    func synthesizeTracksForOrphanRelease(_ entity: CollectionItemEntity) -> Int {
        guard entity.tracks.isEmpty else { return 0 }

        let releaseId = entity.releaseId
        var rde = FetchDescriptor<ReleaseDetailEntity>(
            predicate: #Predicate { $0.releaseId == releaseId }
        )
        rde.fetchLimit = 1
        guard let detailEntity = try? context.fetch(rde).first else {
            return 0
        }

        let detail: ReleaseDetail
        do {
            detail = try JSONDecoder().decode(ReleaseDetail.self, from: detailEntity.jsonData)
        } catch {
            return 0
        }

        guard !detail.tracklist.isEmpty else {
            return 0
        }

        let surrogatePrefix = "discogs:\(releaseId):"
        var existingFD = FetchDescriptor<TrackEntity>(
            predicate: #Predicate { $0.trackMBID.starts(with: surrogatePrefix) }
        )
        let existingSurrogates = Set((try? context.fetch(existingFD))?.map(\.trackMBID) ?? [])
        var created = 0

        // "Various Artists" convention shared with SetBuilderView.isCompilation.
        let isCompilation = entity.basicInformation?.artists.first?.name.lowercased() == "various"
        let releaseArtist = entity.basicInformation?.artists.map(\.name).joined(separator: " & ") ?? ""

        for track in detail.tracklist {
            // Discogs tracklists include heading/index rows (e.g. side headers) with no position.
            guard !track.position.isEmpty else { continue }

            let surrogate = "discogs:\(releaseId):\(track.position)"
            guard !existingSurrogates.contains(surrogate) else { continue }

            let artistCredit: String
            if isCompilation, let trackArtists = track.artists, !trackArtists.isEmpty {
                artistCredit = trackArtists.map(\.name).joined(separator: " & ")
            } else {
                artistCredit = releaseArtist
            }

            let newTrack = TrackEntity(
                trackMBID: surrogate,
                recordingMBID: "",
                position: track.position,
                title: track.title,
                durationMs: track.durationMs,
                artistCredit: artistCredit
            )
            newTrack.collectionItem = entity
            context.insert(newTrack)
            created += 1
        }

        return created
    }

    // ponytail: synthesizeMissingTracksForMatchedRelease/backfillMBIDReleaseTracks used to
    // handle "MBID-matched release, MB returned zero recordings" as a separate case from
    // orphan (no-MBID) releases. Both did the same Discogs-surrogate synthesis with the same
    // ID scheme; now that synthesizeTracksForOrphanRelease/backfillOrphanReleaseTracks above
    // are guarded by tracks.isEmpty instead of mbid emptiness, they cover this case too —
    // removed rather than kept as dead duplicate code.

    func startRefetch() {
        switch phase {
        case .idle, .completed, .cancelled: break
        default: return
        }
        Task {
            let descriptor = FetchDescriptor<CollectionItemEntity>()
            guard let all = try? context.fetch(descriptor) else { return }
            for entity in all where entity.mbid != nil {
                entity.recordingsScanState = RecordingsScanState.unscanned.rawValue
                entity.recordingsScannedAt = nil
                let existing = entity.tracks
                for track in existing { context.delete(track) }
            }
            try? context.save()
            processedCount = 0
            passProcessed = 0
            phase = .idle
            start()
        }
    }
}
