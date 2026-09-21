import Foundation
import SwiftData

@MainActor
@Observable
final class SyncOrchestrator {

    var syncStatus: String = ""
    var isSyncing: Bool = false
    var lastResult: String = ""
    var pendingAnalysisCount: Int = 0
    var showAnalysisConfirmation: Bool = false

    private let collectionViewModel: CollectionViewModel
    private let mbidCoordinator: MBIDScanCoordinator
    private let recordingsCoordinator: RecordingsScanCoordinator
    private let fileMatchCoordinator: FileMatchCoordinator
    private let localAnalysisCoordinator: LocalAnalysisCoordinator
    private let context: ModelContext

    private var analysisContinuation: CheckedContinuation<Bool, Never>?
    private var syncTask: Task<Void, Never>?

    init(
        collectionViewModel: CollectionViewModel,
        mbidCoordinator: MBIDScanCoordinator,
        recordingsCoordinator: RecordingsScanCoordinator,
        fileMatchCoordinator: FileMatchCoordinator,
        localAnalysisCoordinator: LocalAnalysisCoordinator,
        context: ModelContext
    ) {
        self.collectionViewModel = collectionViewModel
        self.mbidCoordinator = mbidCoordinator
        self.recordingsCoordinator = recordingsCoordinator
        self.fileMatchCoordinator = fileMatchCoordinator
        self.localAnalysisCoordinator = localAnalysisCoordinator
        self.context = context
    }

    func startSync() {
        guard !isSyncing else { return }
        isSyncing = true
        syncStatus = "Starting sync…"
        lastResult = ""
        syncTask = Task { await performSync() }
    }

    func confirmAnalysis() {
        analysisContinuation?.resume(returning: true)
        analysisContinuation = nil
        showAnalysisConfirmation = false
    }

    func skipAnalysis() {
        analysisContinuation?.resume(returning: false)
        analysisContinuation = nil
        showAnalysisConfirmation = false
    }

    // MARK: - Orchestration chain

    private func performSync() async {
        defer { isSyncing = false }

        var newReleasesAdded = 0
        var filesAnalyzed = 0

        do {
            // Step 1: Delta detection + additive import
            syncStatus = "Checking Discogs…"
            await collectionViewModel.checkForNewReleases()

            guard case .deltaReady(let delta) = collectionViewModel.syncPhase else {
                if case .failed(let msg) = collectionViewModel.syncPhase {
                    throw SyncError.stageFailed("Discogs check: \(msg)")
                }
                throw SyncError.stageFailed("Unexpected state after Discogs check")
            }

            var newEntities: [CollectionItemEntity] = []

            if !delta.newIDs.isEmpty {
                let n = delta.newIDs.count
                syncStatus = "Importing \(n) new release\(n == 1 ? "" : "s")…"
                let count = await collectionViewModel.importNewReleases(newIDs: delta.newIDs)
                newReleasesAdded = count
                newEntities = fetchEntities(instanceIds: delta.newIDs)
            }

            if !newEntities.isEmpty {
                // Step 2: MBID scan for new releases only
                syncStatus = "Finding MusicBrainz IDs…"
                await mbidCoordinator.startForItems(newEntities)

                // Step 3: Recordings for new releases (needs MBID from step 2)
                syncStatus = "Fetching track listings…"
                for entity in newEntities {
                    guard !Task.isCancelled else { break }
                    await recordingsCoordinator.startForSingle(entity)
                }
            }

            // Step 4: File index + match — incremental Phase 1 inserts only new files;
            // Phase 2 re-matches all tracks. Covers both new-release tracks and new NAS files.
            syncStatus = "Indexing & matching files…"
            await fileMatchCoordinator.startAndAwaitFullScan()

            // Step 5: Count pending analysis before running so the count is visible upfront
            let pending = await localAnalysisCoordinator.pendingFileAnalysisCount()

            if pending > 0 {
                if pending > 200 {
                    pendingAnalysisCount = pending
                    let shouldProceed = await withCheckedContinuation { cont in
                        analysisContinuation = cont
                        showAnalysisConfirmation = true
                    }
                    guard shouldProceed else {
                        let rel = newReleasesAdded
                        lastResult = "Sync complete: \(rel) new release\(rel == 1 ? "" : "s"). Analysis skipped (\(pending) files pending)."
                        syncStatus = lastResult
                        return
                    }
                }

                syncStatus = "Analyzing new tracks (\(pending) files)…"
                await localAnalysisCoordinator.startAndAwaitFileAnalysis()
                filesAnalyzed = localAnalysisCoordinator.analyzedCount
            }

            let rel = newReleasesAdded
            let trk = filesAnalyzed
            lastResult = "Sync complete: \(rel) new release\(rel == 1 ? "" : "s"), \(trk) track\(trk == 1 ? "" : "s") analyzed."
            syncStatus = lastResult

        } catch let e as SyncError {
            if case .stageFailed(let msg) = e {
                syncStatus = "Sync failed at: \(msg)"
                lastResult = syncStatus
            }
        } catch {
            syncStatus = "Sync failed: \(error.localizedDescription)"
            lastResult = syncStatus
        }
    }

    enum SyncError: Error {
        case stageFailed(String)
    }

    private func fetchEntities(instanceIds: Set<Int>) -> [CollectionItemEntity] {
        let all = (try? context.fetch(FetchDescriptor<CollectionItemEntity>())) ?? []
        return all.filter { instanceIds.contains($0.instanceId) }
    }
}
