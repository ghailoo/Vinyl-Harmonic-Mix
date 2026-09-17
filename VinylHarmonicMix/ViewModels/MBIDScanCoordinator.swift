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

    struct NeedsReviewItemInfo: Identifiable {
        let instanceId: Int
        let title: String
        let artist: String
        let candidates: [MBReviewCandidate]
        var id: Int { instanceId }
    }

    var phase: Phase = .idle
    var scanMode: ScanMode = .urlLookup
    var scanned: Int = 0
    var total: Int = 0
    var showBanner: Bool = false
    var currentItem: ScanningItemInfo? = nil
    var enrichmentStatus: String? = nil

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
    var needsReviewCount: Int   { fetchCount(state: .needsReview) }
    var notFoundCount: Int      { fetchCount(state: .notFound) }
    var failedCount: Int        { fetchCount(state: .failed) }
    var unscannedCount: Int     { fetchCount(state: .unscanned) }

    // MARK: - Counts by search-pipeline method (C2)

    private func fetchCount(matchMethod: MBIDMatchMethod) -> Int {
        let rawState: String = MBIDScanState.matchedViaSearch.rawValue
        let rawMethod: String? = matchMethod.rawValue
        let d = FetchDescriptor<CollectionItemEntity>(
            predicate: #Predicate { $0.mbidScanState == rawState && $0.mbidMatchMethod == rawMethod }
        )
        return (try? context.fetchCount(d)) ?? 0
    }

    var viaBarcodeCount: Int       { fetchCount(matchMethod: .barcode) }
    var viaCatalogNumberCount: Int { fetchCount(matchMethod: .catalogNumber) }
    /// Search (strategy 3) and master-lookup (strategy 4) matches are both surfaced as
    /// "via search" — the user-facing breakdown asks for one bucket, not four.
    var viaFuzzySearchCount: Int {
        searchMatchedCount - viaBarcodeCount - viaCatalogNumberCount
    }

    var totalCount: Int {
        (try? context.fetchCount(FetchDescriptor<CollectionItemEntity>())) ?? 0
    }

    var processedSoFar: Int {
        matchedCount + searchMatchedCount + needsReviewCount + notFoundCount + failedCount
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

    var needsReviewItems: [NeedsReviewItemInfo] {
        let d = FetchDescriptor<CollectionItemEntity>(
            predicate: #Predicate { $0.mbidScanState == "needsReview" }
        )
        return ((try? context.fetch(d)) ?? []).map { entity in
            NeedsReviewItemInfo(
                instanceId: entity.instanceId,
                title: entity.basicInformation?.title ?? "Unknown",
                artist: entity.basicInformation?.artists.map(\.name).joined(separator: " & ") ?? "",
                candidates: entity.reviewCandidates
            )
        }
    }

    // MARK: - Subset scan (used by SyncOrchestrator for new-release-only MBID pass)

    /// Awaitable MBID scan scoped to a specific set of entities.
    /// Runs the same URL-lookup logic as performScan() but only over the passed entities,
    /// then chains into the search pipeline (searchFallbackMatch) for whatever is still
    /// unmatched — same "one run does both passes" behavior as the UI-triggered scan (A1).
    /// Skips entities already matched/notFound; only processes unscanned and failed.
    /// Does NOT modify phase/scanned/total (orchestrator owns progress display).
    func startForItems(_ entities: [CollectionItemEntity]) async {
        var saveCounter = 0
        for entity in entities {
            if Task.isCancelled {
                currentItem = nil
                do { try context.save() } catch { print("❌ Save on cancel: \(error)") }
                return
            }

            let state = MBIDScanState(rawValue: entity.mbidScanState) ?? .unscanned
            guard state == .unscanned || state == .failed else { continue }

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
                print("⏸️ startForItems cancelled mid-request for releaseId=\(releaseId), state unchanged")
                try? context.save()
                currentItem = nil
                return
            } catch {
                entity.mbidScanState = MBIDScanState.failed.rawValue
                print("⚠️ startForItems failed item \(releaseId): \(error)")
            }
            entity.mbidScannedAt = Date()

            saveCounter += 1
            if saveCounter >= 10 {
                do { try context.save() } catch { print("❌ Batch save failed: \(error)") }
                saveCounter = 0
            }
        }

        do { try context.save() } catch { print("❌ Final save failed: \(error)") }

        let stillUnmatched = entities.filter {
            let s = MBIDScanState(rawValue: $0.mbidScanState) ?? .unscanned
            return s == .notFound || s == .failed
        }
        for entity in stillUnmatched {
            if Task.isCancelled {
                currentItem = nil
                do { try context.save() } catch { print("❌ Save on cancel: \(error)") }
                return
            }

            currentItem = ScanningItemInfo(
                title: entity.basicInformation?.title ?? "—",
                artist: entity.basicInformation?.artists.first?.name ?? "Unknown artist"
            )
            do {
                let outcome = try await runSearchPipeline(for: entity)
                applyPipelineOutcome(outcome, to: entity)
            } catch is CancellationError {
                print("⏸️ startForItems search fallback cancelled for releaseId=\(entity.releaseId), state unchanged")
                try? context.save()
                currentItem = nil
                return
            } catch {
                entity.mbidScanState = MBIDScanState.failed.rawValue
                print("⚠️ startForItems search fallback failed item \(entity.releaseId): \(error)")
            }
            entity.mbidScannedAt = Date()

            saveCounter += 1
            if saveCounter >= 10 {
                do { try context.save() } catch { print("❌ Batch save failed: \(error)") }
                saveCounter = 0
            }
        }

        do { try context.save() } catch { print("❌ Final save failed: \(error)") }
        currentItem = nil
    }

    // MARK: - Search pipeline (Part B) — strongest identifier first, stop at first VERIFIED match

    private enum MBPipelineOutcome {
        case matched(mbid: String, title: String, artist: String, method: MBIDMatchMethod)
        case needsReview([MBReviewCandidate])
        case notFound
    }

    private struct ScoredCandidate {
        let candidate: MBCandidate
        let score: Double
    }

    /// The shared "search pipeline" strategy used by both the full scan (scanMissingViaSearch)
    /// and the scoped SyncOrchestrator scan (startForItems) — one implementation, two callers.
    /// Order: barcode → label+catno → artist+title fuzzy → Discogs master URL. Stops at the
    /// first strategy whose best candidate clears the identifier/strong-fuzzy bar (B3); anything
    /// merely plausible is pooled for review instead of discarded.
    private func runSearchPipeline(for entity: CollectionItemEntity) async throws -> MBPipelineOutcome {
        let detail = cachedReleaseDetail(for: entity.releaseId)
        let side = discogsSide(for: entity, detail: detail)
        var reviewPool: [ScoredCandidate] = []

        func evaluate(_ candidates: [MBCandidate], identifierMatch: Bool, method: MBIDMatchMethod) -> MBPipelineOutcome? {
            let scored = candidates
                .compactMap { candidate -> ScoredCandidate? in
                    guard let score = MBMatchVerifier.score(candidate: candidate, discogs: side) else { return nil }
                    return ScoredCandidate(candidate: candidate, score: score)
                }
                .sorted { $0.score > $1.score }

            guard let best = scored.first else { return nil }

            if identifierMatch || best.score >= MBMatchThresholds.strongFuzzyAutoAccept {
                return .matched(mbid: best.candidate.mbid, title: best.candidate.title, artist: best.candidate.artist, method: method)
            }

            reviewPool.append(contentsOf: scored.filter { $0.score >= MBMatchThresholds.reviewMinimum })
            return nil
        }

        // 1. Barcode
        if let barcode = extractBarcode(detail), !barcode.isEmpty {
            let candidates = try await client.searchReleasesByBarcode(barcode)
            if let outcome = evaluate(candidates, identifierMatch: true, method: .barcode) { return outcome }
        }

        // 2. Label + catalog number
        if let labelCredit = entity.basicInformation?.labels.first(where: isUsableLabelCredit) {
            let candidates = try await client.searchReleasesByCatalogNumber(catno: labelCredit.catno, label: labelCredit.name)
            if let outcome = evaluate(candidates, identifierMatch: true, method: .catalogNumber) { return outcome }
        }

        // 3. Artist + title, fuzzy — each Discogs artist credit searched separately (B1)
        let artistNames = entity.basicInformation?.artists.map(\.name) ?? []
        let title = entity.basicInformation?.title ?? ""
        let rawYear = entity.basicInformation?.year ?? 0
        let year: Int? = rawYear > 0 ? rawYear : nil
        var fuzzyCandidates: [MBCandidate] = []
        for artistName in (artistNames.isEmpty ? [""] : artistNames) {
            let cleanArtist = MBMatchVerifier.stripDiscogsArtistSuffix(artistName)
            fuzzyCandidates += try await client.searchReleasesByArtistTitle(artist: cleanArtist, title: title, year: year)
        }
        if let outcome = evaluate(fuzzyCandidates, identifierMatch: false, method: .search) { return outcome }

        // 4. Discogs master URL → release-group → pick release inside by format/country/catno
        if let masterId = detail?.masterId,
           let groupMBID = try await client.lookupReleaseGroupMBID(forDiscogsMasterId: masterId) {
            let candidates = try await client.browseReleases(releaseGroupMBID: groupMBID)
            if let outcome = evaluate(candidates, identifierMatch: true, method: .masterLookup) { return outcome }
        }

        guard !reviewPool.isEmpty else { return .notFound }
        let top3 = reviewPool
            .sorted { $0.score > $1.score }
            .prefix(3)
            .map { scored in
                MBReviewCandidate(
                    mbid: scored.candidate.mbid,
                    title: scored.candidate.title,
                    artist: scored.candidate.artist,
                    format: scored.candidate.formats.joined(separator: ", "),
                    country: scored.candidate.country ?? "",
                    date: scored.candidate.date ?? "",
                    catno: scored.candidate.catalogNumbers.first ?? "",
                    score: scored.score
                )
            }
        return .needsReview(Array(top3))
    }

    private func applyPipelineOutcome(_ outcome: MBPipelineOutcome, to entity: CollectionItemEntity) {
        switch outcome {
        case .matched(let mbid, let title, let artist, let method):
            entity.mbid = mbid
            entity.mbidMatchedTitle = title
            entity.mbidMatchedArtist = artist
            entity.mbidMatchMethod = method.rawValue
            entity.mbidScanState = MBIDScanState.matchedViaSearch.rawValue
        case .needsReview(let candidates):
            entity.reviewCandidates = candidates
            entity.mbidScanState = MBIDScanState.needsReview.rawValue
        case .notFound:
            entity.mbidScanState = MBIDScanState.notFound.rawValue
        }
    }

    private func cachedReleaseDetail(for releaseId: Int) -> ReleaseDetail? {
        var descriptor = FetchDescriptor<ReleaseDetailEntity>(
            predicate: #Predicate { $0.releaseId == releaseId }
        )
        descriptor.fetchLimit = 1
        guard let entity = try? context.fetch(descriptor).first else { return nil }
        return try? JSONDecoder().decode(ReleaseDetail.self, from: entity.jsonData)
    }

    private func extractBarcode(_ detail: ReleaseDetail?) -> String? {
        guard let detail else { return nil }
        if let barcodeId = detail.identifiers?.first(where: { $0.type.caseInsensitiveCompare("Barcode") == .orderedSame })?.value {
            return barcodeId
        }
        return detail.barcode
    }

    private func isUsableLabelCredit(_ label: LabelCreditEntity) -> Bool {
        let catno = label.catno.trimmingCharacters(in: .whitespaces).lowercased()
        let name = label.name.trimmingCharacters(in: .whitespaces).lowercased()
        return !catno.isEmpty && catno != "none" && !name.isEmpty && name != "none" && name != "not on label"
    }

    private func discogsSide(for entity: CollectionItemEntity, detail: ReleaseDetail?) -> MBMatchVerifier.DiscogsSide {
        let info = entity.basicInformation
        let rawArtists = (info?.artists.map(\.name) ?? []).map(MBMatchVerifier.stripDiscogsArtistSuffix)
        let formats = (info?.formats ?? []).flatMap { [$0.name] + ($0.descriptions ?? []) }
        let catalogNumber = info?.labels.first(where: isUsableLabelCredit)?.catno
        let rawYear = info?.year ?? 0
        return MBMatchVerifier.DiscogsSide(
            artists: rawArtists.isEmpty ? [""] : rawArtists,
            title: info?.title ?? "",
            formats: formats,
            catalogNumber: catalogNumber,
            country: detail?.country,
            year: rawYear > 0 ? rawYear : nil,
            trackCount: detail?.tracklist.count
        )
    }

    // MARK: - Manual fix actions

    // Store MBID then chain recordings fetch → AcousticBrainz fetch sequentially.
    // Progress is surfaced via enrichmentStatus so the detail popup can observe it.
    func setMBIDManuallyAndEnrich(
        instanceId: Int,
        mbid: String,
        recordingsCoordinator: RecordingsScanCoordinator,
        audioFeaturesCoordinator: AudioFeaturesScanCoordinator
    ) {
        setMBIDManually(instanceId: instanceId, mbid: mbid)
        let id = instanceId
        var descriptor = FetchDescriptor<CollectionItemEntity>(
            predicate: #Predicate { $0.instanceId == id }
        )
        descriptor.fetchLimit = 1
        guard let entity = try? context.fetch(descriptor).first else { return }
        enrichmentStatus = "Fetching tracks…"
        Task {
            await recordingsCoordinator.startForSingle(entity)
            enrichmentStatus = "Fetching audio features…"
            await audioFeaturesCoordinator.startForSingle(entity)
            enrichmentStatus = nil
        }
    }

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
        entity.mbidMatchMethod = nil
        entity.mbidReviewCandidatesData = nil
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
        entity.mbidMatchMethod = nil
        entity.mbidReviewCandidatesData = nil
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

        // A1: one MBID run does URL lookup first, then the search pipeline for whatever
        // is still unmatched — no separate button/hidden second pass required.
        if scanMode == .urlLookup {
            await beginSearchFallbackPass()
        } else {
            phase = .completed
        }
    }

    // MARK: - Search-fallback pass (auto-chained second pass)

    /// Chains directly into the search pass within the same scan Task (no new Task spawned,
    /// since this runs inline at the tail of performScan()).
    private func beginSearchFallbackPass() async {
        scanMode = .searchFallback
        processedCount = 0
        scanned = 0

        let rawNotFound = MBIDScanState.notFound.rawValue
        let rawFailed   = MBIDScanState.failed.rawValue
        let descriptor = FetchDescriptor<CollectionItemEntity>(
            predicate: #Predicate { $0.mbidScanState == rawNotFound || $0.mbidScanState == rawFailed }
        )
        let remaining = (try? context.fetchCount(descriptor)) ?? 0
        total = remaining

        guard remaining > 0 else {
            phase = .completed
            return
        }

        await scanMissingViaSearch()
    }

    /// Used only when resuming a paused search-fallback pass (spawns its own Task since
    /// resume() is a synchronous UI call).
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
            do {
                let outcome = try await runSearchPipeline(for: entity)
                applyPipelineOutcome(outcome, to: entity)
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
                entity.mbidMatchMethod = nil
                entity.mbidReviewCandidatesData = nil
            }
            try? context.save()
            processedCount = 0
            scanned = 0
            phase = .idle
            start()
        }
    }
}
