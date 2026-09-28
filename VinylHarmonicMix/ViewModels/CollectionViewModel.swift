import Foundation
import SwiftData

@Observable
final class CollectionViewModel {
    enum Phase {
        case idle
        case loading(progress: Double)
        case loaded
        case failed(String)
    }

    var items: [CollectionItem] = []
    var phase: Phase = .idle
    var currentPage: Int = 0
    var totalPages: Int = 0
    var isConfigured: Bool = false

    private let client = DiscogsClient()
    private let keychain = KeychainService.shared
    private var detailCache: [Int: ReleaseDetail] = [:]
    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
        loadFromStore()
        refreshConfiguration()
    }

    func refreshConfiguration() {
        isConfigured = keychain.load(for: .token) != nil
                    && keychain.load(for: .username) != nil
    }

    // MARK: - Store bootstrap

    func loadFromStore() {
        guard let entities = try? context.fetch(FetchDescriptor<CollectionItemEntity>()),
              !entities.isEmpty else { return }
        let loaded = entities.compactMap { makeItem(from: $0) }
        guard !loaded.isEmpty else { return }
        items = loaded
        phase = .loaded
    }

    // MARK: - Collection import

    func importCollection() async {
        guard let token = keychain.load(for: .token), !token.isEmpty,
              let username = keychain.load(for: .username), !username.isEmpty else {
            phase = .failed("No credentials saved. Open Settings and save your token and username.")
            return
        }
        phase = .loading(progress: 0)
        currentPage = 0
        totalPages = 0
        items = []
        do {
            let fetched = try await client.fetchCollection(username: username, token: token) { [weak self] page, pages in
                guard let self else { return }
                self.currentPage = page
                self.totalPages = pages
                self.phase = .loading(progress: Double(page) / Double(max(pages, 1)))
            }
            items = fetched
            phase = .loaded
            persist(fetched)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    // MARK: - Release detail

    func loadDetail(for item: CollectionItem) async throws -> ReleaseDetail {
        if let cached = detailCache[item.releaseId] { return cached }

        let releaseId = item.releaseId
        var descriptor = FetchDescriptor<ReleaseDetailEntity>(
            predicate: #Predicate { $0.releaseId == releaseId }
        )
        descriptor.fetchLimit = 1
        if let entity = try? context.fetch(descriptor).first,
           let detail = try? JSONDecoder().decode(ReleaseDetail.self, from: entity.jsonData) {
            detailCache[releaseId] = detail
            return detail
        }

        guard let token = keychain.load(for: .token), !token.isEmpty else {
            throw DiscogsError.unauthorized
        }
        let result = try await client.fetchReleaseDetail(id: releaseId, token: token)
        detailCache[releaseId] = result

        if let data = try? JSONEncoder().encode(result) {
            context.insert(ReleaseDetailEntity(releaseId: releaseId, jsonData: data))
            synthesizeTracksIfNeeded(instanceId: item.id)
            try? context.save()
        }

        return result
    }

    /// Details were just cached for a release that had none before — if it has no
    /// TrackEntity rows yet, synthesize them from the Discogs tracklist now instead of
    /// waiting for the next launch's backfill. Idempotent; never touches a release that
    /// already has tracks (ponytail: reuses RecordingsScanCoordinator's existing guard).
    private func synthesizeTracksIfNeeded(instanceId: Int) {
        var descriptor = FetchDescriptor<CollectionItemEntity>(
            predicate: #Predicate { $0.instanceId == instanceId }
        )
        descriptor.fetchLimit = 1
        guard let entity = try? context.fetch(descriptor).first else { return }
        _ = RecordingsScanCoordinator(context: context).synthesizeTracksForOrphanRelease(entity)
    }

    // MARK: - Persistence helpers

    private func persist(_ fetched: [CollectionItem]) {
        do {
            let existing = try context.fetch(FetchDescriptor<CollectionItemEntity>())

            // Capture MBID state before wiping entities
            var mbidState: [Int: (mbid: String?, scanState: String, scannedAt: Date?, matchedTitle: String?, matchedArtist: String?)] = [:]
            for entity in existing {
                mbidState[entity.instanceId] = (
                    mbid: entity.mbid,
                    scanState: entity.mbidScanState,
                    scannedAt: entity.mbidScannedAt,
                    matchedTitle: entity.mbidMatchedTitle,
                    matchedArtist: entity.mbidMatchedArtist
                )
            }

            for entity in existing { context.delete(entity) }

            for item in fetched {
                let entity = makeEntity(from: item)
                if let saved = mbidState[item.id] {
                    entity.mbid = saved.mbid
                    entity.mbidScanState = saved.scanState
                    entity.mbidScannedAt = saved.scannedAt
                    entity.mbidMatchedTitle = saved.matchedTitle
                    entity.mbidMatchedArtist = saved.matchedArtist
                }
                context.insert(entity)
            }

            try context.save()
        } catch {
            print("⚠️ Persistence error: \(error)")
        }
    }

    // MARK: - Entity ↔ model conversion

    private func makeEntity(from item: CollectionItem) -> CollectionItemEntity {
        let basic = BasicInformationEntity(
            title: item.basicInformation.title,
            year: item.basicInformation.year,
            coverImage: item.basicInformation.coverImage,
            thumb: item.basicInformation.thumb,
            genres: item.basicInformation.genres,
            styles: item.basicInformation.styles
        )
        basic.artists = item.basicInformation.artists.map {
            ArtistCreditEntity(artistId: $0.id, name: $0.name)
        }
        basic.labels = item.basicInformation.labels.map {
            LabelCreditEntity(name: $0.name, catno: $0.catno)
        }
        basic.formats = item.basicInformation.formats.map {
            FormatEntity(name: $0.name, qty: $0.qty, descriptions: $0.descriptions)
        }
        let entity = CollectionItemEntity(
            instanceId: item.id,
            releaseId: item.releaseId,
            folderId: item.folderId,
            rating: item.rating,
            dateAdded: item.dateAdded
        )
        entity.basicInformation = basic
        return entity
    }

    // MARK: - Sync Stage 1: delta detection + additive import

    struct SyncDelta {
        let newIDs: Set<Int>
        let removedIDs: Set<Int>   // informational only — never acted on
        let remoteCount: Int
        let localCount: Int
        var isUpToDate: Bool { newIDs.isEmpty }
    }

    enum SyncPhase {
        case idle
        case checking
        case deltaReady(SyncDelta)
        case importing
        case done(added: Int)
        case failed(String)
    }

    var syncPhase: SyncPhase = .idle

    func checkForNewReleases() async {
        guard let token    = keychain.load(for: .token),    !token.isEmpty,
              let username = keychain.load(for: .username), !username.isEmpty else {
            syncPhase = .failed("No credentials. Configure token and username in Settings.")
            return
        }
        syncPhase = .checking
        do {
            let remote   = try await client.fetchCollectionInstanceIDs(username: username, token: token)
            let localIDs = Set((try? context.fetch(FetchDescriptor<CollectionItemEntity>()))?.map(\.instanceId) ?? [])
            syncPhase = .deltaReady(SyncDelta(
                newIDs:      remote.subtracting(localIDs),
                removedIDs:  localIDs.subtracting(remote),
                remoteCount: remote.count,
                localCount:  localIDs.count
            ))
        } catch {
            syncPhase = .failed(error.localizedDescription)
        }
    }

    /// ADDITIVE import: inserts only the releases whose instanceId is in `newIDs`.
    /// Never deletes any existing entity. Never calls persist(). Existing rows,
    /// their TrackEntity children, file matches, MBID state and harmonic data are untouched.
    func importNewReleases(newIDs: Set<Int>) async -> Int {
        guard !newIDs.isEmpty else { syncPhase = .done(added: 0); return 0 }
        guard let token    = keychain.load(for: .token),    !token.isEmpty,
              let username = keychain.load(for: .username), !username.isEmpty else {
            syncPhase = .failed("No credentials.")
            return 0
        }
        syncPhase = .importing
        do {
            let allItems = try await client.fetchCollection(username: username, token: token)
            let newItems = allItems.filter { newIDs.contains($0.id) }
            // ADDITIVE ONLY — context.insert only, never context.delete
            for item in newItems {
                context.insert(makeEntity(from: item))
            }
            try? context.save()
            loadFromStore()   // rebuild in-memory items from DB
            syncPhase = .done(added: newItems.count)
            return newItems.count
        } catch {
            syncPhase = .failed(error.localizedDescription)
            return 0
        }
    }

    func resetSyncPhase() { syncPhase = .idle }

    // MARK: - SetBuilder lookup cache
    //
    // SetBuilderView is torn down and recreated on every sidebar switch, so the data it
    // shows lives here (state that outlives the view) instead of in @Query arrays that
    // re-materialize every table on each switch. refreshSetBuilderLookups() fetches on a
    // background ModelContext; the O(n) track walk is skipped when the track/feature row
    // counts haven't changed since last time (same key as before). Scan states are small
    // (two fields per release) and always refreshed so the filter counts stay live.
    private(set) var setBuilderCoverageByInstanceId: [Int: (covered: Int, total: Int, localCovered: Int)] = [:]
    private(set) var setBuilderFilePathToInstanceId: [String: Int] = [:]
    private(set) var setBuilderThumbURLs: [String: URL] = [:]
    private(set) var setBuilderConfidentPool: [MixTrack] = []
    private(set) var setBuilderScanStates: [Int: String] = [:]   // instanceId → mbidScanState
    private var setBuilderLastFeaturesCount = -1
    private var setBuilderLastTracksCount = -1
    private var setBuilderRefreshRunning = false
    private var setBuilderRefreshPending = false

    func refreshSetBuilderLookups() {
        guard !setBuilderRefreshRunning else { setBuilderRefreshPending = true; return }
        let featuresCount = (try? context.fetchCount(FetchDescriptor<RecordingFeaturesEntity>())) ?? 0
        let tracksCount   = (try? context.fetchCount(FetchDescriptor<TrackEntity>())) ?? 0
        let rebuild = featuresCount != setBuilderLastFeaturesCount || tracksCount != setBuilderLastTracksCount
        setBuilderRefreshRunning = true
        let container = context.container
        Task {
            PerfLog.begin("CollectionViewModel.refreshSetBuilderLookups(rebuild: \(rebuild)) off-main")
            let result = await Task.detached(priority: .userInitiated) {
                SetBuilderLookups.compute(container: container, rebuild: rebuild)
            }.value
            PerfLog.end("CollectionViewModel.refreshSetBuilderLookups(rebuild: \(rebuild)) off-main")
            setBuilderScanStates = result.scanStates
            if let r = result.rebuilt {
                setBuilderLastFeaturesCount = featuresCount
                setBuilderLastTracksCount = tracksCount
                setBuilderCoverageByInstanceId = r.coverage
                setBuilderFilePathToInstanceId = r.filePathToInstanceId
                setBuilderThumbURLs = r.thumbURLs
                setBuilderConfidentPool = r.confidentPool
            }
            setBuilderRefreshRunning = false
            if setBuilderRefreshPending { setBuilderRefreshPending = false; refreshSetBuilderLookups() }
        }
    }

    // MARK: - Stats page cache
    //
    // CollectionStatsView is rebuilt on every sidebar switch, so it reads this snapshot
    // instead of five unbounded @Query arrays. The snapshot is computed on a background
    // ModelContext; the two expensive parts (decoding every cached Discogs JSON blob, and
    // walking every release's basic info) are reused from the previous snapshot while
    // their source row counts are unchanged — the same keys the view's .task(id:) used.
    //
    // `full` (on appear) recomputes everything, matching the old per-visit .task runs;
    // save-triggered refreshes reuse the expensive parts, matching the old .task(id:) keys.
    // The previous snapshot stays on screen meanwhile, so a revisit renders immediately.
    private(set) var stats: CollectionStats?
    private var statsRefreshRunning = false
    private var statsRefreshPending: Bool?   // nil = none queued, else queued `full`

    func refreshStats(full: Bool) {
        guard !statsRefreshRunning else {
            statsRefreshPending = (statsRefreshPending ?? false) || full
            return
        }
        statsRefreshRunning = true
        let container = context.container
        let reuse = full ? nil : stats
        Task {
            PerfLog.begin("CollectionViewModel.refreshStats(full: \(full)) off-main")
            let fresh = await Task.detached(priority: .userInitiated) {
                CollectionStats.compute(container: container, reuse: reuse)
            }.value
            PerfLog.end("CollectionViewModel.refreshStats(full: \(full)) off-main")
            stats = fresh
            statsRefreshRunning = false
            if let queuedFull = statsRefreshPending {
                statsRefreshPending = nil
                refreshStats(full: queuedFull)
            }
        }
    }

    private func makeItem(from entity: CollectionItemEntity) -> CollectionItem? {
        guard let basic = entity.basicInformation else { return nil }
        let info = BasicInformation(
            title: basic.title,
            year: basic.year,
            coverImage: basic.coverImage,
            thumb: basic.thumb,
            artists: basic.artists.map { ArtistCredit(id: $0.artistId, name: $0.name) },
            labels: basic.labels.map { LabelCredit(name: $0.name, catno: $0.catno) },
            formats: basic.formats.map { Format(name: $0.name, qty: $0.qty, descriptions: $0.descriptions) },
            genres: basic.genres,
            styles: basic.styles
        )
        return CollectionItem(
            id: entity.instanceId,
            releaseId: entity.releaseId,
            folderId: entity.folderId,
            rating: entity.rating,
            dateAdded: entity.dateAdded,
            basicInformation: info
        )
    }
}

// MARK: - Stats snapshot

/// Every number CollectionStatsView displays, computed on a background ModelContext.
/// Field comments name the expression the view used to evaluate over its @Query arrays.
nonisolated struct CollectionStats: Sendable {
    typealias Breakdown = [(label: String, count: Int)]

    // CollectionItemEntity
    var releaseCount = 0                 // entities.count
    var formatCounts: Breakdown = []
    var genreCounts: Breakdown = []
    var decadeCounts: Breakdown = []
    var labelCounts: Breakdown = []
    var artistCounts: Breakdown = []
    var validYears: [Int] = []
    var recordingsFetched = 0
    var recordingsSkipped = 0
    var recordingsFailed = 0

    // ReleaseDetailEntity
    var detailRowCount = 0               // detailEntities.count
    var decodedDetailCount = 0           // cachedDetails.count
    var decodedTrackCount = 0            // cachedDetails' summed tracklist counts
    var decodedDurationSeconds = 0       // cachedDetails' summed track durations

    // TrackEntity
    var trackCount = 0                   // trackEntities.count
    var distinctRecordingMBIDCount = 0   // Set(trackEntities.map(\.recordingMBID)) minus ""

    // RecordingFeaturesEntity (AcousticBrainz)
    var featureCount = 0
    var featuresWithBPM = 0
    var featuresWithKey = 0
    var featuresWithBoth = 0
    var featureBPMsSorted: [Double] = []
    var featureCamelotCounts: [String: Int] = [:]

    // LocalAudioFeaturesEntity
    var settledLocalAnalyzedCount = 0    // local features whose track is still confident
    var localBPMsSorted: [Double] = []
    var localCamelotCounts: [String: Int] = [:]

    // LocalFileEntity
    var totalLocalFileCount = 0
    var localFilesWithCuesCount = 0
    var analyzedLocalFileCount = 0

    /// `reuse`: a previous snapshot whose breakdowns / decoded details are kept while
    /// their source row counts are unchanged. Pass nil to recompute everything.
    static func compute(container: ModelContainer, reuse: CollectionStats?) -> CollectionStats {
        let ctx = ModelContext(container)
        var s = CollectionStats()

        // Releases
        s.releaseCount = (try? ctx.fetchCount(FetchDescriptor<CollectionItemEntity>())) ?? 0
        if let reuse, reuse.releaseCount == s.releaseCount {
            s.formatCounts = reuse.formatCounts
            s.genreCounts  = reuse.genreCounts
            s.decadeCounts = reuse.decadeCounts
            s.labelCounts  = reuse.labelCounts
            s.artistCounts = reuse.artistCounts
            s.validYears   = reuse.validYears
        } else {
            s.computeBreakdowns(ctx)
        }
        s.recordingsFetched = count(ctx, #Predicate<CollectionItemEntity> { $0.recordingsScanState == "fetched" })
        s.recordingsSkipped = count(ctx, #Predicate<CollectionItemEntity> { $0.recordingsScanState == "skipped" })
        s.recordingsFailed  = count(ctx, #Predicate<CollectionItemEntity> { $0.recordingsScanState == "failed" })

        // Cached Discogs details — the JSON blobs are only loaded when the row count moved.
        s.detailRowCount = (try? ctx.fetchCount(FetchDescriptor<ReleaseDetailEntity>())) ?? 0
        if let reuse, reuse.detailRowCount == s.detailRowCount {
            s.decodedDetailCount     = reuse.decodedDetailCount
            s.decodedTrackCount      = reuse.decodedTrackCount
            s.decodedDurationSeconds = reuse.decodedDurationSeconds
        } else {
            var fd = FetchDescriptor<ReleaseDetailEntity>()
            fd.propertiesToFetch = [\.jsonData]
            let decoder = JSONDecoder()
            for entity in (try? ctx.fetch(fd)) ?? [] {
                guard let detail = try? decoder.decode(ReleaseDetail.self, from: entity.jsonData) else { continue }
                s.decodedDetailCount += 1
                s.decodedTrackCount += detail.tracklist.count
                for track in detail.tracklist { s.decodedDurationSeconds += parseDuration(track.duration) }
            }
        }

        // Tracks
        s.trackCount = (try? ctx.fetchCount(FetchDescriptor<TrackEntity>())) ?? 0
        var trackFD = FetchDescriptor<TrackEntity>()
        trackFD.propertiesToFetch = [\.recordingMBID]
        s.distinctRecordingMBIDCount = Set(((try? ctx.fetch(trackFD)) ?? []).map(\.recordingMBID).filter { !$0.isEmpty }).count

        // AcousticBrainz features
        var featureFD = FetchDescriptor<RecordingFeaturesEntity>()
        featureFD.propertiesToFetch = [\.bpm, \.keyNote, \.camelotCode]
        let features = (try? ctx.fetch(featureFD)) ?? []
        s.featureCount     = features.count
        s.featuresWithBPM  = features.filter { $0.bpm != nil }.count
        s.featuresWithKey  = features.filter { $0.keyNote != nil }.count
        s.featuresWithBoth = features.filter { $0.bpm != nil && $0.keyNote != nil }.count
        s.featureBPMsSorted = features.compactMap(\.bpm).sorted()
        s.featureCamelotCounts = Dictionary(features.compactMap(\.camelotCode).map { ($0, 1) }, uniquingKeysWith: +)

        // Local analysis. track ↔ localAudioFeatures is a one-to-one inverse pair, so
        // "features whose track is confident" == "confident tracks that have features".
        s.settledLocalAnalyzedCount = count(ctx, #Predicate<TrackEntity> {
            $0.fileMatchState == "confident" && $0.localAudioFeatures != nil
        })
        var localFD = FetchDescriptor<LocalAudioFeaturesEntity>()
        localFD.propertiesToFetch = [\.bpm, \.camelot]
        let localFeatures = (try? ctx.fetch(localFD)) ?? []
        s.localBPMsSorted = localFeatures.map(\.bpm).filter { $0 > 0 }.sorted()
        s.localCamelotCounts = Dictionary(localFeatures.map(\.camelot).filter { !$0.isEmpty }.map { ($0, 1) }, uniquingKeysWith: +)

        // Local files
        s.totalLocalFileCount     = (try? ctx.fetchCount(FetchDescriptor<LocalFileEntity>())) ?? 0
        s.localFilesWithCuesCount = count(ctx, #Predicate<LocalFileEntity> { $0.cuePoints.count > 0 })
        s.analyzedLocalFileCount  = count(ctx, #Predicate<LocalFileEntity> { $0.bpm > 0 })
        return s
    }

    /// Single pass over every release's basic info (was CollectionStatsView.recomputeBreakdowns).
    private mutating func computeBreakdowns(_ ctx: ModelContext) {
        let excludedArtists: Set<String> = ["various", "various artists", "unknown artist"]
        var formats: [String: Int] = [:]
        var genres: [String: Int] = [:]
        var decades: [Int: Int] = [:]
        var labels: [String: Int] = [:]
        var artists: [String: Int] = [:]
        var years: [Int] = []

        var fd = FetchDescriptor<CollectionItemEntity>()
        fd.propertiesToFetch = [\.instanceId]
        fd.relationshipKeyPathsForPrefetching = [\.basicInformation]
        for entity in (try? ctx.fetch(fd)) ?? [] {
            let info = entity.basicInformation
            formats[info?.formats.first?.name ?? "Unknown", default: 0] += 1
            for genre in info?.genres ?? [] {
                genres[genre, default: 0] += 1
            }
            if let year = info?.year, year > 0 {
                years.append(year)
                decades[(year / 10) * 10, default: 0] += 1
            }
            if let name = info?.labels.first?.name {
                labels[name, default: 0] += 1
            }
            if let name = info?.artists.first?.name, !excludedArtists.contains(name.lowercased()) {
                artists[name, default: 0] += 1
            }
        }

        formatCounts = formats.sorted { $0.value > $1.value }.map { (label: $0.key, count: $0.value) }
        genreCounts  = genres.sorted { $0.value > $1.value }.map { (label: $0.key, count: $0.value) }
        decadeCounts = decades.sorted { $0.key < $1.key }.map { (label: "\($0.key)s", count: $0.value) }
        labelCounts  = labels.sorted { $0.value > $1.value }.map { (label: $0.key, count: $0.value) }
        artistCounts = artists.sorted { $0.value > $1.value }.map { (label: $0.key, count: $0.value) }
        validYears   = years
    }

    private static func count<T: PersistentModel>(_ ctx: ModelContext, _ predicate: Predicate<T>) -> Int {
        (try? ctx.fetchCount(FetchDescriptor<T>(predicate: predicate))) ?? 0
    }

    static func parseDuration(_ s: String) -> Int {
        guard !s.isEmpty else { return 0 }
        let parts = s.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return 0 }
        return parts[0] * 60 + parts[1]
    }
}

// MARK: - SetBuilder lookups snapshot

nonisolated struct SetBuilderLookups: Sendable {
    struct Rebuilt: Sendable {
        var coverage: [Int: (covered: Int, total: Int, localCovered: Int)]
        var filePathToInstanceId: [String: Int]
        var thumbURLs: [String: URL]
        var confidentPool: [MixTrack]
    }
    var scanStates: [Int: String]
    var rebuilt: Rebuilt?

    static func compute(container: ModelContainer, rebuild: Bool) -> SetBuilderLookups {
        let ctx = ModelContext(container)

        var itemFD = FetchDescriptor<CollectionItemEntity>()
        itemFD.propertiesToFetch = [\.instanceId, \.mbidScanState]
        let scanStates = Dictionary(((try? ctx.fetch(itemFD)) ?? []).map { ($0.instanceId, $0.mbidScanState) },
                                    uniquingKeysWith: { first, _ in first })
        guard rebuild else { return SetBuilderLookups(scanStates: scanStates, rebuilt: nil) }

        // Only "has AcousticBrainz BPM + Camelot" is ever read from the features.
        var featureFD = FetchDescriptor<RecordingFeaturesEntity>()
        featureFD.propertiesToFetch = [\.recordingMBID, \.bpm, \.camelotCode]
        var abCovered = Set<String>()
        for f in (try? ctx.fetch(featureFD)) ?? [] where f.bpm != nil && f.camelotCode != nil {
            abCovered.insert(f.recordingMBID)
        }

        var trackFD = FetchDescriptor<TrackEntity>()
        trackFD.relationshipKeyPathsForPrefetching = [\.collectionItem, \.localAudioFeatures]
        let tracks = (try? ctx.fetch(trackFD)) ?? []

        var totals: [Int: Int] = [:]
        var coveredCounts: [Int: Int] = [:]
        var localCounts: [Int: Int] = [:]
        var fpToId: [String: Int] = [:]
        fpToId.reserveCapacity(tracks.count)
        for track in tracks {
            guard let id = track.collectionItem?.instanceId else { continue }
            totals[id, default: 0] += 1
            let hasEffectiveBpm = track.effectiveBpm != nil
            let hasLocalSource  = track.featureSource == .local
            let hasAbBpm = abCovered.contains(track.recordingMBID)
            if hasEffectiveBpm || hasAbBpm { coveredCounts[id, default: 0] += 1 }
            if hasLocalSource              { localCounts[id, default: 0] += 1 }
            if let fp = track.primaryLocalFilePath, !fp.isEmpty { fpToId[fp] = id }
        }

        let coverage = Dictionary(uniqueKeysWithValues: totals.keys.map { id in
            (id, (covered: coveredCounts[id] ?? 0, total: totals[id]!, localCovered: localCounts[id] ?? 0))
        })
        return SetBuilderLookups(scanStates: scanStates, rebuilt: Rebuilt(
            coverage: coverage,
            filePathToInstanceId: fpToId,
            thumbURLs: MixCoverArt.thumbURLs(from: tracks),
            confidentPool: MixTrackPool.confident(from: tracks)
        ))
    }
}
