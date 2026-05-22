import Foundation
import SwiftData

@MainActor
@Observable
final class AudioFeaturesScanCoordinator {

    enum Phase {
        case idle
        case scanning
        case paused
        case completed
        case cancelled
        case failed(String)
    }

    var phase: Phase = .idle
    var batchesProcessed: Int = 0
    var batchesTotal: Int = 0
    var tracksFound: Int = 0
    var tracksMissing: Int = 0
    var tracksFailed: Int = 0
    var currentBatchPreview: String? = nil
    var showBanner: Bool = false
    var isEnrichPass: Bool = false

    private let context: ModelContext
    private let client = AcousticBrainzClient()
    private var scanTask: Task<Void, Never>?
    private var processedBatches: Int = 0
    private var secondsPerBatch: Double = 2.2

    init(context: ModelContext) {
        self.context = context
    }

    // MARK: - Live counts

    var unqueriedCount: Int {
        let allTracks = (try? context.fetch(FetchDescriptor<TrackEntity>())) ?? []
        let tracksWithMBID = Set(allTracks.compactMap { $0.recordingMBID.isEmpty ? nil : $0.recordingMBID })
        let allFeatures = (try? context.fetch(FetchDescriptor<RecordingFeaturesEntity>())) ?? []
        let queriedSet = Set(allFeatures.map(\.recordingMBID))
        return tracksWithMBID.filter { !queriedSet.contains($0) }.count
    }

    var missingBatchCount: Int {
        let all = (try? context.fetch(FetchDescriptor<RecordingFeaturesEntity>())) ?? []
        return all.filter { $0.bpm == nil }.count
    }

    var noBpmCount: Int { missingBatchCount }

    var foundCount: Int {
        let all = (try? context.fetch(FetchDescriptor<RecordingFeaturesEntity>())) ?? []
        return all.filter { $0.bpm != nil }.count
    }

    var shouldShowPanel: Bool {
        switch phase {
        case .scanning, .paused, .completed, .cancelled, .failed: return true
        case .idle: return false
        }
    }

    var estimatedRemainingMinutes: Int {
        guard case .scanning = phase, batchesProcessed > 0, batchesTotal > 0 else { return 0 }
        let remaining = max(0, batchesTotal - batchesProcessed)
        let seconds = Double(remaining) * secondsPerBatch
        return Int(ceil(seconds / 60.0))
    }

    // MARK: - Controls

    func start() {
        switch phase {
        case .idle, .completed, .cancelled: break
        default: return
        }
        isEnrichPass = false
        secondsPerBatch = 2.2
        processedBatches = 0
        batchesProcessed = 0
        tracksFound = 0
        tracksMissing = 0
        tracksFailed = 0
        startScanInternal()
    }

    func startEnrich() {
        switch phase {
        case .idle, .completed, .cancelled: break
        default: return
        }
        isEnrichPass = true
        secondsPerBatch = 1.1
        processedBatches = 0
        batchesProcessed = 0
        tracksFound = 0
        tracksMissing = 0
        tracksFailed = 0
        startEnrichInternal()
    }

    // Fetch AcousticBrainz features for a single release's tracks.
    // Scopes the queue to recording MBIDs from that entity only, skipping already-queried ones.
    // Refuses to run if a batch scan is already in progress.
    func startForSingle(_ entity: CollectionItemEntity) async {
        switch phase {
        case .scanning, .paused: return
        default: break
        }
        let entityTracks = entity.tracks
        let uniqueMBIDs = Array(Set(entityTracks.compactMap {
            $0.recordingMBID.isEmpty ? nil : $0.recordingMBID
        }))
        guard !uniqueMBIDs.isEmpty else { return }
        let allFeatures = (try? context.fetch(FetchDescriptor<RecordingFeaturesEntity>())) ?? []
        let queriedSet = Set(allFeatures.map(\.recordingMBID))
        let queue = uniqueMBIDs.filter { !queriedSet.contains($0) }
        let batches = stride(from: 0, to: queue.count, by: 25).map {
            Array(queue[$0..<min($0 + 25, queue.count)])
        }
        guard !batches.isEmpty else { return }
        isEnrichPass = false
        processedBatches = 0
        batchesProcessed = 0
        batchesTotal = batches.count
        tracksFound = 0
        tracksMissing = 0
        tracksFailed = 0
        phase = .scanning
        showBanner = true
        await performScan(batches: batches)
    }

    func refetchMissing() {
        switch phase {
        case .idle, .completed, .cancelled: break
        default: return
        }
        Task {
            let all = (try? context.fetch(FetchDescriptor<RecordingFeaturesEntity>())) ?? []
            for entity in all where entity.bpm == nil { context.delete(entity) }
            try? context.save()
            processedBatches = 0
            batchesProcessed = 0
            tracksFound = 0
            tracksMissing = 0
            tracksFailed = 0
            startScanInternal()
        }
    }

    func rescanAll() {
        switch phase {
        case .idle, .completed, .cancelled: break
        default: return
        }
        Task {
            let all = (try? context.fetch(FetchDescriptor<RecordingFeaturesEntity>())) ?? []
            for entity in all { context.delete(entity) }
            try? context.save()
            processedBatches = 0
            batchesProcessed = 0
            tracksFound = 0
            tracksMissing = 0
            tracksFailed = 0
            startScanInternal()
        }
    }

    func resume() {
        guard case .paused = phase else { return }
        if isEnrichPass {
            startEnrichInternal()
        } else {
            startScanInternal()
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
        currentBatchPreview = nil
        phase = .cancelled
    }

    func dismissPanel() {
        phase = .idle
        batchesProcessed = 0
        batchesTotal = 0
        processedBatches = 0
        showBanner = false
    }

    // MARK: - Internals

    private func startScanInternal() {
        phase = .scanning
        showBanner = true

        let allTracks = (try? context.fetch(FetchDescriptor<TrackEntity>())) ?? []
        let uniqueMBIDs = Array(Set(allTracks.compactMap { $0.recordingMBID.isEmpty ? nil : $0.recordingMBID }))
        let allFeatures = (try? context.fetch(FetchDescriptor<RecordingFeaturesEntity>())) ?? []
        let queriedSet = Set(allFeatures.map(\.recordingMBID))
        let queue = uniqueMBIDs.filter { !queriedSet.contains($0) }

        let batches = stride(from: 0, to: queue.count, by: 25).map {
            Array(queue[$0..<min($0 + 25, queue.count)])
        }

        batchesTotal = processedBatches + batches.count

        if batches.isEmpty {
            phase = .completed
            return
        }

        scanTask = Task { await performScan(batches: batches) }
    }

    private func performScan(batches: [[String]]) async {
        var saveCounter = 0

        for batch in batches {
            if Task.isCancelled {
                try? context.save()
                currentBatchPreview = nil
                return
            }

            currentBatchPreview = batch.first.map { String($0.prefix(8)) + "…" }

            do {
                let high = try await client.fetchFeatures(recordingMBIDs: batch)
                let low  = try await client.fetchLowLevel(recordingMBIDs: batch)

                for mbid in batch {
                    let key = mbid.lowercased()
                    let highFeat = high.results[key]
                    let lowFeat  = low.results[key]

                    let entity = RecordingFeaturesEntity(recordingMBID: mbid)

                    if let h = highFeat {
                        entity.danceabilityValue    = h.danceabilityValue
                        entity.moodHappy            = h.moodHappy
                        entity.moodPartyProb        = h.moodPartyProb
                        entity.moodElectronicProb   = h.moodElectronicProb
                        entity.moodAcousticProb     = h.moodAcousticProb
                        entity.danceabilityLabel    = h.danceabilityLabel
                        entity.danceabilityProb     = h.danceabilityProb
                        entity.genreDortmund        = h.genreDortmund
                    }
                    if let l = lowFeat {
                        entity.bpm          = l.bpm
                        entity.keyNote      = l.keyNote
                        entity.keyScale     = l.keyScale
                        entity.keyConfidence = l.keyConfidence
                        entity.camelotCode  = CamelotConverter.camelotCode(forNote: l.keyNote, scale: l.keyScale)
                    }

                    context.insert(entity)

                    if entity.bpm != nil { tracksFound  += 1 }
                    else                 { tracksMissing += 1 }
                }

            } catch is CancellationError {
                print("⏸️ Audio features scan cancelled mid-batch")
                try? context.save()
                currentBatchPreview = nil
                return
            } catch {
                print("⚠️ Audio features batch failed: \(error)")
                tracksFailed += batch.count
            }

            processedBatches += 1
            batchesProcessed = processedBatches
            saveCounter += 1

            if saveCounter >= 5 {
                do { try context.save() } catch { print("❌ Batch save: \(error)") }
                saveCounter = 0
            }
        }

        do { try context.save() } catch { print("❌ Final save: \(error)") }
        currentBatchPreview = nil
        phase = .completed
    }

    // MARK: - Enrich pass (fills BPM/key into existing rows that have highlevel data)

    private func startEnrichInternal() {
        phase = .scanning
        showBanner = true

        let allFeatures = (try? context.fetch(FetchDescriptor<RecordingFeaturesEntity>())) ?? []
        let noBpmRows = allFeatures.filter { $0.bpm == nil }
        let lookup = Dictionary(uniqueKeysWithValues: noBpmRows.map { ($0.recordingMBID, $0) })
        let mbids = Array(lookup.keys)

        let batches = stride(from: 0, to: mbids.count, by: 25).map {
            Array(mbids[$0..<min($0 + 25, mbids.count)])
        }

        batchesTotal = processedBatches + batches.count

        if batches.isEmpty {
            phase = .completed
            return
        }

        scanTask = Task { await performEnrich(batches: batches, lookup: lookup) }
    }

    private func performEnrich(batches: [[String]], lookup: [String: RecordingFeaturesEntity]) async {
        var saveCounter = 0

        for batch in batches {
            if Task.isCancelled {
                try? context.save()
                currentBatchPreview = nil
                return
            }

            currentBatchPreview = batch.first.map { String($0.prefix(8)) + "…" }

            do {
                let low = try await client.fetchLowLevel(recordingMBIDs: batch)

                for mbid in batch {
                    let key = mbid.lowercased()
                    guard let entity = lookup[mbid] ?? lookup[key] else { continue }

                    if let l = low.results[key] {
                        entity.bpm           = l.bpm
                        entity.keyNote       = l.keyNote
                        entity.keyScale      = l.keyScale
                        entity.keyConfidence = l.keyConfidence
                        entity.camelotCode   = CamelotConverter.camelotCode(forNote: l.keyNote, scale: l.keyScale)
                        entity.fetchedAt     = .now
                        tracksFound  += 1
                    } else {
                        tracksMissing += 1
                    }
                }

            } catch is CancellationError {
                print("⏸️ BPM enrich cancelled mid-batch")
                try? context.save()
                currentBatchPreview = nil
                return
            } catch {
                print("⚠️ Low-level batch failed: \(error)")
                tracksFailed += batch.count
            }

            processedBatches += 1
            batchesProcessed = processedBatches
            saveCounter += 1

            if saveCounter >= 5 {
                do { try context.save() } catch { print("❌ Batch save: \(error)") }
                saveCounter = 0
            }
        }

        do { try context.save() } catch { print("❌ Final save: \(error)") }
        currentBatchPreview = nil
        phase = .completed
    }
}
