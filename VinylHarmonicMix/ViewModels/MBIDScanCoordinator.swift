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

    var phase: Phase = .idle
    var scanMode: ScanMode = .urlLookup
    var scanned: Int = 0
    var total: Int = 0
    var unscannedCount: Int = 0
    var notFoundCount: Int = 0
    var showBanner: Bool = false

    private let context: ModelContext
    private let client = MusicBrainzClient()
    private var scanTask: Task<Void, Never>?
    private var processedCount: Int = 0

    init(context: ModelContext) {
        self.context = context
        refreshCounts()
    }

    // MARK: - Count refresh

    func refreshUnscannedCount() {
        let descriptor = FetchDescriptor<CollectionItemEntity>(
            predicate: #Predicate { $0.mbidScanState == "unscanned" }
        )
        unscannedCount = (try? context.fetchCount(descriptor)) ?? 0
    }

    func refreshNotFoundCount() {
        let descriptor = FetchDescriptor<CollectionItemEntity>(
            predicate: #Predicate { $0.mbidScanState == "notFound" }
        )
        notFoundCount = (try? context.fetchCount(descriptor)) ?? 0
    }

    private func refreshCounts() {
        refreshUnscannedCount()
        refreshNotFoundCount()
    }

    // MARK: - URL-lookup pass (first pass)

    func start() {
        guard case .idle = phase else { return }
        scanMode = .urlLookup
        processedCount = 0
        scanned = 0
        startScan()
    }

    private func startScan() {
        phase = .scanning
        showBanner = true

        let descriptor = FetchDescriptor<CollectionItemEntity>(
            predicate: #Predicate { $0.mbidScanState == "unscanned" }
        )
        let remaining = (try? context.fetchCount(descriptor)) ?? 0
        total = processedCount + remaining

#if DEBUG
        let allRows = (try? context.fetchCount(FetchDescriptor<CollectionItemEntity>())) ?? -1
        let matchedRows = (try? context.fetchCount(FetchDescriptor<CollectionItemEntity>(predicate: #Predicate { $0.mbidScanState == "matched" }))) ?? -1
        print("📊 Scanner sees: total=\(total) (= already processed \(processedCount) + remaining \(remaining))")
        print("📊 Total CollectionItemEntity rows in store: \(allRows)")
        print("📊 Rows where mbidScanState == matched: \(matchedRows)")
#endif

        scanTask = Task { await performScan() }
    }

    private func performScan() async {
        // Fetch all unscanned entities once — avoids SwiftData pending-change
        // cache returning 0 results on re-fetch inside a mutation loop.
        let descriptor = FetchDescriptor<CollectionItemEntity>(
            predicate: #Predicate { $0.mbidScanState == "unscanned" }
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
                do { try context.save() } catch { print("❌ Save on cancel failed: \(error)") }
                return
            }

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
            } catch {
                entity.mbidScanState = MBIDScanState.failed.rawValue
                print("⚠️ Failed item \(releaseId): \(error)")
                // TODO: add retry-failed-items action
            }
            entity.mbidScannedAt = Date()

            processedCount += 1
            scanned = processedCount
            saveCounter += 1

            if saveCounter >= 10 {
                do {
                    try context.save()
                    print("💾 Batch saved after \(saveCounter) items at position \(processedCount)/\(queue.count)")
                } catch {
                    print("❌ Batch save failed: \(error)")
                }
                saveCounter = 0
            }
        }

        do { try context.save() } catch { print("❌ Final save failed: \(error)") }

        phase = .completed
        refreshCounts()
        scheduleAutoDismiss()
    }

    // MARK: - Search-fallback pass (second pass)

    func startSearchScan() {
        print("🟢 [2] startSearchScan() entered, phase=\(phase)")
        switch phase {
        case .idle, .completed, .cancelled: break
        default:
            print("🟢 [2] guard failed — phase \(phase) is not startable")
            return
        }
        scanMode = .searchFallback
        processedCount = 0
        scanned = 0
        print("🟢 [2b] Past guard, calling startSearchScanInternal()")
        startSearchScanInternal()
        print("🟢 [2c] startSearchScanInternal() returned, phase=\(phase)")
    }

    private func startSearchScanInternal() {
        phase = .scanning
        showBanner = true

        let descriptor = FetchDescriptor<CollectionItemEntity>(
            predicate: #Predicate { $0.mbidScanState == "notFound" }
        )
        let remaining = (try? context.fetchCount(descriptor)) ?? 0
        total = processedCount + remaining
        print("🟢 [3] startSearchScanInternal: remaining=\(remaining), total=\(total)")

        scanTask = Task {
            print("🟢 [3a] Task started, calling scanMissingViaSearch()")
            await scanMissingViaSearch()
            print("🟢 [3b] scanMissingViaSearch() returned")
        }
    }

    private func scanMissingViaSearch() async {
        print("🟡 [4] scanMissingViaSearch() entered")
        let descriptor = FetchDescriptor<CollectionItemEntity>(
            predicate: #Predicate { $0.mbidScanState == "notFound" }
        )
        let queue: [CollectionItemEntity]
        do {
            queue = try context.fetch(descriptor)
            print("🟡 [4a] Fetched \(queue.count) notFound entities")
        } catch {
            print("🔴 [4b] Fetch failed: \(error)")
            phase = .failed("Database fetch failed: \(error.localizedDescription)")
            return
        }
        if queue.isEmpty {
            print("🟡 [4c] Queue empty — exiting")
            phase = .completed
            refreshCounts()
            scheduleAutoDismiss()
            return
        }
        print("🟡 [4d] About to start processing loop")

        var saveCounter = 0
        for entity in queue {
            print("🟡 [5] Processing item \(processedCount + 1) of \(queue.count): releaseId=\(entity.releaseId)")
            if Task.isCancelled {
                do { try context.save() } catch { print("❌ Save on cancel failed: \(error)") }
                return
            }

            // Join artist names with space — MusicBrainz indexes individual names better than "&"
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
                    print("💾 Batch saved after \(saveCounter) items at position \(processedCount)/\(queue.count)")
                } catch {
                    print("❌ Batch save failed: \(error)")
                }
                saveCounter = 0
            }
        }

        do { try context.save() } catch { print("❌ Final save failed: \(error)") }

        phase = .completed
        refreshCounts()
        scheduleAutoDismiss()
    }

    // MARK: - Shared controls

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
        phase = .cancelled
    }

    func dismissBanner() {
        showBanner = false
        phase = .idle
        scanned = 0
        total = 0
        processedCount = 0
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
            refreshCounts()
            processedCount = 0
            scanned = 0
            phase = .idle
            start()
        }
    }

    private func scheduleAutoDismiss() {
        Task {
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            if case .completed = phase {
                showBanner = false
            }
        }
    }
}
