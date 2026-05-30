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
        guard entity.mbid != nil else { return }
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

    /// Back-fills synthetic TrackEntity rows for any orphan release already in the
    /// database that doesn't yet have tracks. Safe to call on every launch — idempotent
    /// (skips any release whose tracks array is already non-empty).
    func backfillOrphanReleaseTracks() {
        let all = (try? context.fetch(FetchDescriptor<CollectionItemEntity>())) ?? []
        let orphans = all.filter { ($0.mbid ?? "").isEmpty && $0.tracks.isEmpty }
        guard !orphans.isEmpty else { return }
        var totalCreated = 0
        let processed = orphans.count
        for entity in orphans {
            totalCreated += synthesizeTracksForOrphanRelease(entity)
        }
        if totalCreated > 0 { try? context.save() }
    }

    /// Synthesize TrackEntity rows for a release that has no MusicBrainz release MBID.
    /// Uses the Discogs tracklist as the source of truth. Each synthesized track gets
    /// trackMBID = "discogs:{releaseId}:{position}" (unique, stable, visually distinct
    /// from real MB UUIDs), recordingMBID = "" (empty, signals "no MB binding"),
    /// and fileMatchState = "unscanned" (so the UI shows the "Set file" button).
    ///
    /// Idempotent: if a TrackEntity with the synthesized trackMBID already exists,
    /// it is left untouched.
    ///
    /// Returns the number of new TrackEntity rows created.
    @discardableResult
    func synthesizeTracksForOrphanRelease(_ entity: CollectionItemEntity) -> Int {
        guard (entity.mbid ?? "").isEmpty else { return 0 }

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

        for track in detail.tracklist {
            let surrogate = "discogs:\(releaseId):\(track.position)"
            guard !existingSurrogates.contains(surrogate) else { continue }
            let newTrack = TrackEntity(
                trackMBID: surrogate,
                recordingMBID: "",
                position: track.position,
                title: track.title,
                durationMs: nil,
                artistCredit: ""
            )
            newTrack.collectionItem = entity
            context.insert(newTrack)
            created += 1
        }

        return created
    }

    // MARK: - MBID release synthesis

    /// Synthesizes surrogate TrackEntity rows for a MBID-matched release whose MB fetch
    /// returned zero recordings. Uses the cached Discogs tracklist as the source.
    ///
    /// Surrogate trackMBID = "discogs:{releaseId}:{position}" — same stable scheme as
    /// orphan releases, so the "Set file" button appears immediately.
    ///
    /// Idempotent: skips any position where a TrackEntity (surrogate or real) already
    /// exists. When processItems runs later and MB returns real data, it will delete
    /// these surrogates and insert real MB tracks.
    ///
    /// Returns the number of new TrackEntity rows created.
    @discardableResult
    func synthesizeMissingTracksForMatchedRelease(_ entity: CollectionItemEntity) -> Int {
        guard let mbid = entity.mbid, !mbid.isEmpty else { return 0 }

        let releaseId = entity.releaseId
        var rde = FetchDescriptor<ReleaseDetailEntity>(
            predicate: #Predicate { $0.releaseId == releaseId }
        )
        rde.fetchLimit = 1
        guard let detailEntity = try? context.fetch(rde).first else { return 0 }

        let detail: ReleaseDetail
        do {
            detail = try JSONDecoder().decode(ReleaseDetail.self, from: detailEntity.jsonData)
        } catch {
            return 0
        }

        guard !detail.tracklist.isEmpty else { return 0 }

        let existingPositions = Set(entity.tracks.map(\.position))
        let surrogatePrefix   = "discogs:\(releaseId):"
        var created = 0

        for track in detail.tracklist {
            guard !existingPositions.contains(track.position) else { continue }
            let newTrack = TrackEntity(
                trackMBID: "\(surrogatePrefix)\(track.position)",
                recordingMBID: "",
                position: track.position,
                title: track.title,
                durationMs: nil,
                artistCredit: ""
            )
            newTrack.collectionItem = entity
            context.insert(newTrack)
            created += 1
        }

        return created
    }

    /// Back-fills surrogate TrackEntity rows for all MBID-matched releases that currently
    /// have zero tracks — typically because MB returned an empty recordings list for that
    /// release MBID. Safe to call on every launch (idempotent).
    func backfillMBIDReleaseTracks() {
        let all = (try? context.fetch(FetchDescriptor<CollectionItemEntity>())) ?? []
        let mbidEmpty = all.filter { ($0.mbid ?? "").isEmpty == false && $0.tracks.isEmpty }
        guard !mbidEmpty.isEmpty else { return }
        var totalCreated = 0
        for entity in mbidEmpty {
            totalCreated += synthesizeMissingTracksForMatchedRelease(entity)
        }
        if totalCreated > 0 {
            print("🎵 Synthesized \(totalCreated) surrogate tracks for \(mbidEmpty.count) MBID releases with empty MB data")
            try? context.save()
        }
    }

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
