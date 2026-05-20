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

    private func loadFromStore() {
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
