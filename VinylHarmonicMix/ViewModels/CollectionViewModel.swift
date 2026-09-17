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
            try? context.save()
        }

        return result
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
    // SetBuilderView is torn down and recreated on every sidebar switch, so its onAppear
    // can't tell whether these derived lookups are already up to date. Caching them here
    // (state that outlives the view) lets rebuildSetBuilderLookupsIfNeeded skip the O(n)
    // rebuild when the underlying track/feature counts haven't changed since last time.
    private(set) var setBuilderFeaturesByMBID: [String: RecordingFeaturesEntity] = [:]
    private(set) var setBuilderCoverageByInstanceId: [Int: (covered: Int, total: Int, localCovered: Int)] = [:]
    private(set) var setBuilderFilePathToInstanceId: [String: Int] = [:]
    private(set) var setBuilderThumbURLs: [String: URL] = [:]
    private(set) var setBuilderConfidentPool: [MixTrack] = []
    private var setBuilderLastFeaturesCount = -1
    private var setBuilderLastTracksCount = -1

    @discardableResult
    func rebuildSetBuilderLookupsIfNeeded(features: [RecordingFeaturesEntity], tracks: [TrackEntity]) -> Bool {
        guard features.count != setBuilderLastFeaturesCount || tracks.count != setBuilderLastTracksCount else {
            return false
        }
        setBuilderLastFeaturesCount = features.count
        setBuilderLastTracksCount = tracks.count

        var featuresByMBID: [String: RecordingFeaturesEntity] = [:]
        featuresByMBID.reserveCapacity(features.count)
        for f in features { featuresByMBID[f.recordingMBID] = f }

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
            let f = featuresByMBID[track.recordingMBID]
            let hasAbBpm = f?.bpm != nil && f?.camelotCode != nil
            if hasEffectiveBpm || hasAbBpm { coveredCounts[id, default: 0] += 1 }
            if hasLocalSource              { localCounts[id, default: 0] += 1 }
            if let fp = track.primaryLocalFilePath, !fp.isEmpty { fpToId[fp] = id }
        }

        setBuilderFeaturesByMBID = featuresByMBID
        setBuilderCoverageByInstanceId = Dictionary(uniqueKeysWithValues: totals.keys.map { id in
            (id, (covered: coveredCounts[id] ?? 0, total: totals[id]!, localCovered: localCounts[id] ?? 0))
        })
        setBuilderFilePathToInstanceId = fpToId
        setBuilderThumbURLs = MixCoverArt.thumbURLs(from: tracks)
        setBuilderConfidentPool = MixTrackPool.confident(from: tracks)
        return true
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
