import Foundation
import SwiftData

@MainActor
@Observable
final class FingerprintScanCoordinator {

    enum Phase {
        case idle, running, paused, completed, cancelled
        var isIdle: Bool {
            switch self { case .idle, .completed, .cancelled: return true; default: return false }
        }
    }

    // MARK: - Observable state

    var phase: Phase = .idle
    var currentTrackLabel: String = ""
    var totalCount: Int = 0
    var processedCount: Int = 0
    var promotedCount: Int = 0
    var ambiguousCount: Int = 0
    var failedCount: Int = 0
    var lastError: String? = nil

    var shouldShowPanel: Bool { phase != .idle }

    var reviewCount: Int {
        (try? context.fetchCount(FetchDescriptor<TrackEntity>(
            predicate: #Predicate { $0.fileMatchState == "review" }
        ))) ?? 0
    }

    private let context: ModelContext
    private var scanTask: Task<Void, Never>?
    private var pendingLimit: Int? = nil

    init(context: ModelContext) { self.context = context }

    // MARK: - Controls

    func startScan(limit: Int? = nil) {
        guard phase == .idle || phase == .completed || phase == .cancelled else { return }
        pendingLimit = limit
        phase = .running
        processedCount = 0; totalCount = 0
        promotedCount = 0; ambiguousCount = 0; failedCount = 0
        currentTrackLabel = ""; lastError = nil

        scanTask = Task { [weak self] in
            guard let self else { return }
            await self.runScan(limit: limit)
            guard !Task.isCancelled else { return }
            if self.phase == .running { self.phase = .completed }
        }
    }

    func startTestBatch() { startScan(limit: 10) }

    func pause() {
        scanTask?.cancel(); scanTask = nil
        phase = .paused
    }

    func resume() {
        guard phase == .paused else { return }
        startScan(limit: pendingLimit)
    }

    func cancel() {
        scanTask?.cancel(); scanTask = nil
        phase = .cancelled
    }

    func dismissPanel() {
        phase = .idle
        processedCount = 0; totalCount = 0
        promotedCount = 0; ambiguousCount = 0; failedCount = 0
        currentTrackLabel = ""; lastError = nil
    }

    // MARK: - Scan loop

    private func runScan(limit: Int?) async {
        guard let fpcalcPath = LocalLibraryService.fpcalcPath() else {
            lastError = "fpcalc not found — install with: brew install chromaprint"
            phase = .completed
            return
        }
        guard let apiKey = KeychainService.shared.load(for: .acoustIDKey), !apiKey.isEmpty else {
            lastError = "AcoustID API key not configured in Settings"
            phase = .completed
            return
        }

        let client = AcoustIDClient(fpcalcPath: fpcalcPath, apiKey: apiKey)

        // Snapshot review tracks that have candidate files (Sendable value types only)
        let allReview = (try? context.fetch(FetchDescriptor<TrackEntity>(
            predicate: #Predicate { $0.fileMatchState == "review" }
        ))) ?? []
        let withCandidates = allReview.filter { !$0.candidateFilePaths.isEmpty }
        let scoped = limit.map { Array(withCandidates.prefix($0)) } ?? withCandidates

        struct ReviewSummary: Sendable {
            let id: PersistentIdentifier
            let recordingMBID: String
            let candidatePaths: [String]
            let title: String
            let artist: String
        }

        let summaries: [ReviewSummary] = scoped.map { t in
            ReviewSummary(id: t.persistentModelID,
                          recordingMBID: t.recordingMBID,
                          candidatePaths: t.candidateFilePaths,
                          title: t.title,
                          artist: t.artistCredit)
        }

        // Seed locked paths: files already claimed by confident/skip tracks.
        // Updated in-loop as we promote, so two review tracks can't both claim the same file.
        var lockedPaths: Set<String> = Set(
            ((try? context.fetch(FetchDescriptor<TrackEntity>())) ?? [])
                .filter { ["confident", "skip"].contains($0.fileMatchState) }
                .compactMap { $0.primaryLocalFilePath }
        )

        totalCount = summaries.count

        for (i, summary) in summaries.enumerated() {
            if Task.isCancelled { break }
            currentTrackLabel = "\(summary.artist) – \(summary.title)"

            var promoted = false
            var hadError = false

            // Try best-scoring candidates first, cap at 3 to limit API cost.
            // fpcalc runs on AcoustIDClient's actor executor (not main thread).
            for path in summary.candidatePaths.prefix(3) {
                if Task.isCancelled { break }
                if lockedPaths.contains(path) { continue }

                do {
                    let fp     = try await client.fingerprint(filePath: path)
                    let result = try await client.lookup(fingerprint: fp.fingerprint,
                                                         duration: fp.duration)

                    if result.recordingMBIDs.contains(summary.recordingMBID) {
                        if promoteToConfident(trackID: summary.id,
                                              filePath: path,
                                              score: result.topScore) {
                            lockedPaths.insert(path)
                            promoted = true
                            print("[FINGERPRINT] ✓ \(summary.artist) – \(summary.title)"
                                  + " → \(URL(fileURLWithPath: path).lastPathComponent)")
                        }
                        break   // found the match; stop trying other candidates
                    }
                    // MBID mismatch: this file is a different recording — try next candidate
                } catch is CancellationError {
                    return
                } catch {
                    hadError = true
                    print("[FINGERPRINT] ✗ \(URL(fileURLWithPath: path).lastPathComponent):"
                          + " \(error.localizedDescription)")
                    // Continue to next candidate — one bad file doesn't abort the track
                }
            }

            if promoted         { promotedCount += 1 }
            else if hadError    { failedCount   += 1 }
            else                { ambiguousCount += 1 }

            processedCount = i + 1
        }

        try? context.save()
    }

    // MARK: - Write-back

    // Atomically links file ↔ track and promotes track to confident.
    // Returns false (without writing) if the file is already owned by a different confident track.
    // Invariant: confident ⟺ live file link, same as name matching.
    @discardableResult
    private func promoteToConfident(trackID: PersistentIdentifier,
                                    filePath: String,
                                    score: Double) -> Bool {
        guard let track = context.model(for: trackID) as? TrackEntity else { return false }

        let path = filePath
        var fd = FetchDescriptor<LocalFileEntity>(predicate: #Predicate { $0.filePath == path })
        fd.fetchLimit = 1
        guard let file = try? context.fetch(fd).first else { return false }

        // Dedup: don't steal a file that already belongs to a different confident track
        if let existingOwner = file.track,
           existingOwner.persistentModelID != track.persistentModelID,
           existingOwner.fileMatchState == "confident" {
            return false
        }

        file.track = track
        file.matchMethod = "fingerprint"
        file.matchScore = score
        track.fileMatchState = "confident"
        track.primaryLocalFilePath = filePath
        try? context.save()
        return true
    }
}
