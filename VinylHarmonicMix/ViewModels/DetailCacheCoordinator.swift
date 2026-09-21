import Foundation
import SwiftData

@MainActor
@Observable
final class DetailCacheCoordinator {

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

    var phase: Phase = .idle
    var passProcessed: Int = 0
    var passTotal: Int = 0
    var currentItem: ScanningItemInfo? = nil
    var newlyCachedCount: Int = 0
    private(set) var totalCollectionCount: Int = 0

    private let context: ModelContext
    private let client = DiscogsClient()
    private let keychain = KeychainService.shared
    private let recordingsCoordinator: RecordingsScanCoordinator
    private var cacheTask: Task<Void, Never>?
    private var processedCount: Int = 0
    private(set) var isRefreshMode: Bool = false
    private(set) var initialQueueCount: Int = 0

    init(context: ModelContext) {
        self.context = context
        self.recordingsCoordinator = RecordingsScanCoordinator(context: context)
    }

    // MARK: - Panel state

    var shouldShowPanel: Bool {
        switch phase {
        case .scanning, .paused, .completed, .cancelled, .failed: return true
        case .idle: return false
        }
    }

    var estimatedRemainingMinutes: Int {
        guard case .scanning = phase, passProcessed > 0, passTotal > passProcessed else { return 0 }
        let remaining = max(0, passTotal - passProcessed)
        let seconds = Double(remaining) * 1.1
        return Int(ceil(seconds / 60.0))
    }

    // MARK: - Controls

    func start() {
        let allItems = (try? context.fetch(FetchDescriptor<CollectionItemEntity>())) ?? []
        let cachedIds: Set<Int> = Set(
            (try? context.fetch(FetchDescriptor<ReleaseDetailEntity>()))?.map(\.releaseId) ?? []
        )
        let queue = allItems.filter { !cachedIds.contains($0.releaseId) }
        print("📊 Detail cache start: \(allItems.count) total items, \(cachedIds.count) already cached, \(queue.count) to fetch")
        if queue.isEmpty {
            print("⚠️ Queue is empty — nothing to do. Either everything is already cached or the predicate is wrong.")
            return
        }

        switch phase {
        case .idle, .completed, .cancelled: break
        default: return
        }
        isRefreshMode = false
        processedCount = 0
        passProcessed = 0
        newlyCachedCount = 0
        phase = .scanning
        cacheTask = Task { await performCache() }
    }

    func startRefresh() {
        switch phase {
        case .idle, .completed, .cancelled: break
        default: return
        }
        isRefreshMode = true
        processedCount = 0
        passProcessed = 0
        newlyCachedCount = 0
        phase = .scanning
        cacheTask = Task { await performCache() }
    }

    func pause() {
        phase = .paused
        cacheTask?.cancel()
        cacheTask = nil
        try? context.save()
    }

    func resume() {
        guard case .paused = phase else { return }
        phase = .scanning
        cacheTask = Task { await performCache() }
    }

    func cancel() {
        cacheTask?.cancel()
        cacheTask = nil
        currentItem = nil
        phase = .cancelled
    }

    func dismissPanel() {
        phase = .idle
        passProcessed = 0
        passTotal = 0
        processedCount = 0
        newlyCachedCount = 0
    }

    // MARK: - Fetch loop

    private func performCache() async {
        guard let token = keychain.load(for: .token), !token.isEmpty else {
            phase = .failed("No Discogs token. Open Settings.")
            return
        }

        let allItems: [CollectionItemEntity]
        do {
            allItems = try context.fetch(FetchDescriptor<CollectionItemEntity>())
        } catch {
            phase = .failed("Database fetch failed: \(error.localizedDescription)")
            return
        }
        totalCollectionCount = allItems.count

        let queue: [CollectionItemEntity]
        if isRefreshMode {
            queue = allItems
        } else {
            let cachedIds: Set<Int>
            do {
                cachedIds = Set(try context.fetch(FetchDescriptor<ReleaseDetailEntity>()).map(\.releaseId))
            } catch {
                phase = .failed("Database fetch failed: \(error.localizedDescription)")
                return
            }
            queue = allItems.filter { !cachedIds.contains($0.releaseId) }
        }

        // processedCount carries over from before a pause, giving correct passTotal on resume
        initialQueueCount = queue.count
        passTotal = processedCount + queue.count

        var saveCounter = 0
        for entity in queue {
            if Task.isCancelled {
                currentItem = nil
                try? context.save()
                return
            }

            currentItem = ScanningItemInfo(
                title: entity.basicInformation?.title ?? "—",
                artist: entity.basicInformation?.artists.first?.name ?? "Unknown artist"
            )

            let releaseId = entity.releaseId
            do {
                let data = try await client.fetchReleaseDetailRaw(id: releaseId, token: token)

                var checkDesc = FetchDescriptor<ReleaseDetailEntity>(
                    predicate: #Predicate { $0.releaseId == releaseId }
                )
                checkDesc.fetchLimit = 1

                if let existing = (try? context.fetch(checkDesc))?.first {
                    existing.jsonData = data
                    existing.fetchedAt = .now
                } else {
                    context.insert(ReleaseDetailEntity(releaseId: releaseId, jsonData: data))
                }
                // ponytail: reuses the existing idempotent, tracks.isEmpty-guarded synthesis —
                // details for this release just landed, so a release with no tracks yet can
                // get them now instead of waiting for the next launch's backfill.
                _ = recordingsCoordinator.synthesizeTracksForOrphanRelease(entity)
                newlyCachedCount += 1
                saveCounter += 1
            } catch {
                print("⚠️ Failed to cache release \(releaseId): \(error)")
            }

            passProcessed += 1
            processedCount += 1

            if saveCounter >= 10 {
                try? context.save()
                saveCounter = 0
            }
        }

        try? context.save()
        currentItem = nil
        phase = .completed
    }
}
