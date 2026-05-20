import Foundation
import SwiftData

@MainActor
@Observable
final class MBIDScanCoordinator {

    enum Phase {
        case idle
        case scanning
        case paused
        case completed
        case cancelled
        case failed(String)
    }

    enum ScanMode {
        case urlLookup
        case searchFallback
    }

    enum ScanPass {
        case urlRelationship
        case indexedSearch
    }

    struct ScanningItemInfo {
        let title: String
        let artist: String
    }

    struct FailedItemInfo: Identifiable {
        let instanceId: Int
        let title: String
        let artist: String
        let error: String
        var id: Int { instanceId }
    }

    var phase: Phase = .idle
    var scanMode: ScanMode = .urlLookup
    var scanned: Int = 0
    var total: Int = 0
    var showBanner: Bool = false
    var currentItem: ScanningItemInfo? = nil

    // Per-pass progress (aliases for scanned/total — updated each iteration)
    var passProcessed: Int { scanned }
    var passTotal: Int     { total }

    private let context: ModelContext
    private let client = MusicBrainzClient()
    private var scanTask: Task<Void, Never>?
    private var processedCount: Int = 0

    init(context: ModelContext) {
        self.context = context
    }

    // MARK: - Live counts (computed on each access; re-evaluated on processedCount change)

    private func fetchCount(state: MBIDScanState) -> Int {
        let raw = state.rawValue
        let d = FetchDescriptor<CollectionItemEntity>(
            predicate: #Predicate { $0.mbidScanState == raw }
        )
        return (try? context.fetchCount(d)) ?? 0
    }

    var matchedCount: Int       { fetchCount(state: .matched) }
    var searchMatchedCount: Int { fetchCount(state: .matchedViaSearch) }
    var manualMatchCount: Int   { fetchCount(state: .matchedManually) }
    var notFoundCount: Int      { fetchCount(state: .notFound) }
    var failedCount: Int        { fetchCount(state: .failed) }
    var unscannedCount: Int     { fetchCount(state: .unscanned) }

    var totalCount: Int {
        (try? context.fetchCount(FetchDescriptor<CollectionItemEntity>())) ?? 0
    }

    var processedSoFar: Int {
        matchedCount + searchMatchedCount + notFoundCount + failedCount
    }

    var overallMatchRate: Double {
        Double(matchedCount + searchMatchedCount + manualMatchCount) / Double(max(totalCount, 1))
    }

    var failedItems: [FailedItemInfo] {
        let d = FetchDescriptor<CollectionItemEntity>(
            predicate: #Predicate { $0.mbidScanState == "failed" }
        )
        return ((try? context.fetch(d)) ?? []).map { entity in
            FailedItemInfo(
                instanceId: entity.instanceId,
                title: entity.basicInformation?.title ?? "Unknown",
                artist: entity.basicInformation?.artists.map(\.name).joined(separator: " & ") ?? "",
                error: "Network error or invalid response"
            )
        }
    }

    // MARK: - Manual fix actions

    func resetToNotFound(instanceId: Int) {
        let id = instanceId
        var descriptor = FetchDescriptor<CollectionItemEntity>(
            predicate: #Predicate { $0.instanceId == id }
        )
        descriptor.fetchLimit = 1
        guard let entity = try? context.fetch(descriptor).first else { return }
        entity.mbidScanState = MBIDScanState.notFound.rawValue
        entity.mbid = nil
        entity.mbidScannedAt = nil
        entity.mbidMatchedTitle = nil
        entity.mbidMatchedArtist = nil
        try? context.save()
    }

    func setMBIDManually(instanceId: Int, mbid: String) {
        let id = instanceId
        var descriptor = FetchDescriptor<CollectionItemEntity>(
            predicate: #Predicate { $0.instanceId == id }
        )
        descriptor.fetchLimit = 1
        guard let entity = try? context.fetch(descriptor).first else { return }
        entity.mbid = mbid
        entity.mbidScanState = MBIDScanState.matchedManually.rawValue
        entity.mbidMatchedTitle = nil
        entity.mbidMatchedArtist = nil
        entity.mbidScannedAt = Date()
        try? context.save()
    }

    // MARK: - Panel state

    var currentPass: ScanPass {
        scanMode == .urlLookup ? .urlRelationship : .indexedSearch
    }

    var shouldShowPanel: Bool {
        switch phase {
        case .scanning, .paused, .completed, .cancelled, .failed: return true
        case .idle: return false
        }
    }

    var estimatedRemainingMinutes: Int {
        guard case .scanning = phase, scanned > 0, total > 0 else { return 0 }
        let remaining = max(0, total - scanned)
        let seconds = Double(remaining) * 1.05
        return Int(ceil(seconds / 60.0))
    }

    // MARK: - URL-lookup pass (first pass)

    func start() {
        switch phase {
        case .idle, .completed: break
        default: return
        }
        scanMode = .urlLookup
        processedCount = 0
        scanned = 0
        startScan()
    }

    private func startScan() {
        phase = .scanning
        showBanner = true

        let rawUnscanned = MBIDScanState.unscanned.rawValue
        let rawFailed = MBIDScanState.failed.rawValue
        let descriptor = FetchDescriptor<CollectionItemEntity>(
            predicate: #Predicate { $0.mbidScanState == rawUnscanned || $0.mbidScanState == rawFailed }
        )
        let remaining = (try? context.fetchCount(descriptor)) ?? 0
        total = processedCount + remaining

#if DEBUG
        let allRows = (try? context.fetchCount(FetchDescriptor<CollectionItemEntity>())) ?? -1
        print("📊 Scanner sees: total=\(total) (processed \(processedCount) + remaining \(remaining)), allRows=\(allRows)")
#endif

        scanTask = Task { await performScan() }
    }

    private func performScan() async {
        // Single up-front fetch — avoids SwiftData pending-change cache returning 0
        // on re-fetch inside a mutation loop.
        let rawUnscanned = MBIDScanState.unscanned.rawValue
        let rawFailed    = MBIDScanState.failed.rawValue
        let descriptor = FetchDescriptor<CollectionItemEntity>(
            predicate: #Predicate { $0.mbidScanState == rawUnscanned || $0.mbidScanState == rawFailed }
        )
        let queue: [CollectionItemEntity]
        do {
            queue = try context.fetch(descriptor)
        } catch {
            print("❌ Scan fetch failed: \(error)")
            phase = .failed("Database fetch failed: \(error.localizedDescription)")
            return
        }
        print("🔍 Loaded \(queue.count) unscanned entities to process")

        var saveCounter = 0
        for entity in queue {
            if Task.isCancelled {
                currentItem = nil
                do { try context.save() } catch { print("❌ Save on cancel: \(error)") }
                return
            }

            currentItem = ScanningItemInfo(
                title: entity.basicInformation?.title ?? "—",
                artist: entity.basicInformation?.artists.first?.name ?? "Unknown artist"
            )
            let releaseId = entity.releaseId
            do {
                let match = try await client.findMBID(forDiscogsReleaseId: releaseId)
                if let match {
                    entity.mbid = match.mbid
                    entity.mbidMatchedTitle = match.title
                    entity.mbidMatchedArtist = match.artist
                    entity.mbidScanState = MBIDScanState.matched.rawValue
                } else {
                    entity.mbidScanState = MBIDScanState.notFound.rawValue
                }
            } catch is CancellationError {
                print("⏸️ Scan cancelled mid-request for releaseId=\(releaseId), state unchanged")
                try? context.save()
                currentItem = nil
                return
            } catch {
                entity.mbidScanState = MBIDScanState.failed.rawValue
                print("⚠️ Failed item \(releaseId): \(error)")
            }
            entity.mbidScannedAt = Date()

            processedCount += 1
            scanned = processedCount
            saveCounter += 1

            if saveCounter >= 10 {
                do {
                    try context.save()
                } catch {
                    print("❌ Batch save failed: \(error)")
                }
                saveCounter = 0
            }
        }

        do { try context.save() } catch { print("❌ Final save failed: \(error)") }
        currentItem = nil
        phase = .completed
    }

    // MARK: - Search-fallback pass (second pass)

    func startSearchScan() {
        switch phase {
        case .idle, .completed, .cancelled: break
        default: return
        }
        scanMode = .searchFallback
        processedCount = 0
        scanned = 0
        startSearchScanInternal()
    }

    private func startSearchScanInternal() {
        phase = .scanning
        showBanner = true

        let rawNotFound = MBIDScanState.notFound.rawValue
        let rawFailed   = MBIDScanState.failed.rawValue
        let descriptor = FetchDescriptor<CollectionItemEntity>(
            predicate: #Predicate { $0.mbidScanState == rawNotFound || $0.mbidScanState == rawFailed }
        )
        let remaining = (try? context.fetchCount(descriptor)) ?? 0
        total = processedCount + remaining

        scanTask = Task { await scanMissingViaSearch() }
    }

    private func scanMissingViaSearch() async {
        let rawNotFound = MBIDScanState.notFound.rawValue
        let rawFailed   = MBIDScanState.failed.rawValue
        let descriptor = FetchDescriptor<CollectionItemEntity>(
            predicate: #Predicate { $0.mbidScanState == rawNotFound || $0.mbidScanState == rawFailed }
        )
        let queue: [CollectionItemEntity]
        do {
            queue = try context.fetch(descriptor)
        } catch {
            phase = .failed("Database fetch failed: \(error.localizedDescription)")
            return
        }
        if queue.isEmpty {
            phase = .completed
            return
        }

        var saveCounter = 0
        for entity in queue {
            if Task.isCancelled {
                currentItem = nil
                do { try context.save() } catch { print("❌ Save on cancel: \(error)") }
                return
            }

            currentItem = ScanningItemInfo(
                title: entity.basicInformation?.title ?? "—",
                artist: entity.basicInformation?.artists.first?.name ?? "Unknown artist"
            )
            let artistName = entity.basicInformation?.artists.map(\.name).joined(separator: " ") ?? ""
            let title = entity.basicInformation?.title ?? ""
            let rawYear = entity.basicInformation?.year ?? 0
            let year: Int? = rawYear > 0 ? rawYear : nil

            do {
                let match = try await client.searchMBID(artist: artistName, title: title, year: year)
                if let match {
                    entity.mbid = match.mbid
                    entity.mbidMatchedTitle = match.title
                    entity.mbidMatchedArtist = match.artist
                    entity.mbidScanState = MBIDScanState.matchedViaSearch.rawValue
                }
                // nil → score below threshold; leave state as notFound
            } catch is CancellationError {
                print("⏸️ Search scan cancelled mid-request for releaseId=\(entity.releaseId), state unchanged")
                try? context.save()
                currentItem = nil
                return
            } catch {
                entity.mbidScanState = MBIDScanState.failed.rawValue
                print("⚠️ Search failed item \(entity.releaseId): \(error)")
            }
            entity.mbidScannedAt = Date()

            processedCount += 1
            scanned = processedCount
            saveCounter += 1

            if saveCounter >= 10 {
                do {
                    try context.save()
                } catch {
                    print("❌ Batch save failed: \(error)")
                }
                saveCounter = 0
            }
        }

        do { try context.save() } catch { print("❌ Final save failed: \(error)") }
        currentItem = nil
        phase = .completed
    }

    // MARK: - Controls

    func resume() {
        guard case .paused = phase else { return }
        switch scanMode {
        case .urlLookup:      startScan()
        case .searchFallback: startSearchScanInternal()
        }
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
        scanned = 0
        total = 0
        processedCount = 0
        showBanner = false
    }

    func startRescan() {
        Task {
            let descriptor = FetchDescriptor<CollectionItemEntity>()
            guard let entities = try? context.fetch(descriptor) else { return }
            for entity in entities {
                entity.mbidScanState = MBIDScanState.unscanned.rawValue
                entity.mbid = nil
                entity.mbidScannedAt = nil
                entity.mbidMatchedTitle = nil
                entity.mbidMatchedArtist = nil
            }
            try? context.save()
            processedCount = 0
            scanned = 0
            phase = .idle
            start()
        }
    }
}
