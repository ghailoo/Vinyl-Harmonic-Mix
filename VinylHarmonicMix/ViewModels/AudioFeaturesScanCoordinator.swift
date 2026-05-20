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

    private let context: ModelContext
    private let client = AcousticBrainzClient()
    private var scanTask: Task<Void, Never>?
    private var processedBatches: Int = 0

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
        let seconds = Double(remaining) * 1.1
        return Int(ceil(seconds / 60.0))
    }

    // MARK: - Controls

    func start() {
        switch phase {
        case .idle, .completed, .cancelled: break
        default: return
        }
        processedBatches = 0
        batchesProcessed = 0
        tracksFound = 0
        tracksMissing = 0
        tracksFailed = 0
        startScanInternal()
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
                let result = try await client.fetchFeatures(recordingMBIDs: batch)

                for (mbid, features) in result.results {
                    let entity = RecordingFeaturesEntity(recordingMBID: mbid)
                    entity.bpm = features.bpm
                    entity.keyNote = features.keyNote
                    entity.keyScale = features.keyScale
                    entity.keyConfidence = features.keyConfidence
                    entity.danceabilityValue = features.danceabilityValue
                    entity.moodHappy = features.moodHappy
                    entity.moodPartyProb = features.moodPartyProb
                    entity.moodElectronicProb = features.moodElectronicProb
                    entity.moodAcousticProb = features.moodAcousticProb
                    entity.danceabilityLabel = features.danceabilityLabel
                    entity.danceabilityProb = features.danceabilityProb
                    entity.genreDortmund = features.genreDortmund
                    entity.camelotCode = CamelotConverter.camelotCode(forNote: features.keyNote, scale: features.keyScale)
                    context.insert(entity)
                    tracksFound += 1
                }

                for mbid in result.missing {
                    let entity = RecordingFeaturesEntity(recordingMBID: mbid)
                    context.insert(entity)
                    tracksMissing += 1
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
}
