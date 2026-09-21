import SwiftUI
import SwiftData

@main
struct VinylHarmonicMixApp: App {
    private let container: ModelContainer
    @State private var settingsViewModel = SettingsViewModel()
    @State private var collectionViewModel: CollectionViewModel
    @State private var scanCoordinator: MBIDScanCoordinator
    @State private var cacheCoordinator: DetailCacheCoordinator
    @State private var recordingsCoordinator: RecordingsScanCoordinator
    @State private var audioFeaturesCoordinator: AudioFeaturesScanCoordinator
    @State private var fileMatchCoordinator: FileMatchCoordinator
    @State private var fingerprintCoordinator: FingerprintScanCoordinator
    @State private var localAnalysisCoordinator: LocalAnalysisCoordinator
    @State private var cueDetectionCoordinator: CueDetectionCoordinator
    @State private var audioPlaybackController: AudioPlaybackController
    @State private var syncOrchestrator: SyncOrchestrator
    @State private var driveMonitor: DriveMonitor
    @State private var showLaunchRestorePrompt = false
    @State private var launchBackupURL: URL?
    @State private var launchBackupEntries: Int = 0

    /// Sandbox is disabled so the default store path moves to ~/Library/Application Support/.
    /// Pin to the container path so existing Discogs/MusicBrainz data is preserved regardless
    /// of sandbox state. SwiftData will auto-migrate the schema on first open.
    static func storeURL() -> URL {
        let bundleID = Bundle.main.bundleIdentifier ?? "VinylHarmonicMix"
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/\(bundleID)/Data/Library/Application Support/default.store")
    }

    init() {
        do {
            let schema = Schema([
                CollectionItemEntity.self,
                BasicInformationEntity.self,
                ArtistCreditEntity.self,
                LabelCreditEntity.self,
                FormatEntity.self,
                ReleaseDetailEntity.self,
                TrackEntity.self,
                RecordingFeaturesEntity.self,
                LocalFileEntity.self,
                LocalAudioFeaturesEntity.self,
                SetlistEntity.self,
                SetlistItemEntity.self,
                CuePointEntity.self,
            ])
            let config = ModelConfiguration(url: Self.storeURL())
            container = try ModelContainer(for: schema, configurations: config)
        } catch {
            fatalError("SwiftData container init failed: \(error)")
        }
        let ctx = container.mainContext

        // One-time: wipe the stale/duplicated LocalFileEntity index so the next
        // "Match all" re-scans cleanly with parentFolder populated.
        // Guarded by a UserDefaults flag so it runs exactly once.
        let wipeKey = "didClearLocalFileIndexV2"
        if !UserDefaults.standard.bool(forKey: wipeKey) {
            let stale = (try? ctx.fetch(FetchDescriptor<LocalFileEntity>())) ?? []
            if !stale.isEmpty {
                for entity in stale { ctx.delete(entity) }
                try? ctx.save()
                print("🧹 Cleared \(stale.count) stale LocalFileEntity rows — re-index needed")
            }
            UserDefaults.standard.set(true, forKey: wipeKey)
        }

        let cv      = CollectionViewModel(context: ctx)
        let scan    = MBIDScanCoordinator(context: ctx)
        let recs    = RecordingsScanCoordinator(context: ctx)
        let audio   = AudioFeaturesScanCoordinator(context: ctx)
        let monitor = DriveMonitor()
        let files   = FileMatchCoordinator(context: ctx, driveMonitor: monitor)
        let local   = LocalAnalysisCoordinator(context: ctx)
        let cue     = CueDetectionCoordinator(context: ctx)

        _collectionViewModel        = State(initialValue: cv)
        _scanCoordinator            = State(initialValue: scan)
        _cacheCoordinator           = State(initialValue: DetailCacheCoordinator(context: ctx))
        _recordingsCoordinator      = State(initialValue: recs)
        _audioFeaturesCoordinator   = State(initialValue: audio)
        _driveMonitor               = State(initialValue: monitor)
        _fileMatchCoordinator       = State(initialValue: files)
        _fingerprintCoordinator     = State(initialValue: FingerprintScanCoordinator(context: ctx))
        _localAnalysisCoordinator   = State(initialValue: local)
        _cueDetectionCoordinator    = State(initialValue: cue)
        _audioPlaybackController    = State(initialValue: AudioPlaybackController(modelContainer: container))
        _syncOrchestrator           = State(initialValue: SyncOrchestrator(
            collectionViewModel:       cv,
            mbidCoordinator:           scan,
            recordingsCoordinator:     recs,
            fileMatchCoordinator:      files,
            localAnalysisCoordinator:  local,
            context:                   ctx
        ))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(settingsViewModel)
                .environment(collectionViewModel)
                .environment(scanCoordinator)
                .environment(cacheCoordinator)
                .environment(recordingsCoordinator)
                .environment(audioFeaturesCoordinator)
                .environment(fileMatchCoordinator)
                .environment(fingerprintCoordinator)
                .environment(localAnalysisCoordinator)
                .environment(cueDetectionCoordinator)
                .environment(audioPlaybackController)
                .environment(syncOrchestrator)
                .environment(driveMonitor)
                .task {
                    fileMatchCoordinator.onScanCompleted = {
                        Task { @MainActor in
                            MatchesBackupService.autoUpdateBackupIfPossible(modelContext: container.mainContext)
                        }
                    }
                    recordingsCoordinator.backfillOrphanReleaseTracks()
#if DEBUG
                    let ctx = container.mainContext
                    let itemDescriptor = FetchDescriptor<CollectionItemEntity>()
                    let detailDescriptor = FetchDescriptor<ReleaseDetailEntity>()
                    let itemCount = (try? ctx.fetchCount(itemDescriptor)) ?? -1
                    let detailCount = (try? ctx.fetchCount(detailDescriptor)) ?? -1
                    let allItems = (try? ctx.fetch(itemDescriptor)) ?? []
                    let distinctIds = Set(allItems.map(\.instanceId)).count
                    let fileCount = (try? ctx.fetchCount(FetchDescriptor<LocalFileEntity>())) ?? -1
                    print("📊 SwiftData state: CollectionItemEntity rows = \(itemCount), distinct instanceIds = \(distinctIds), ReleaseDetailEntity rows = \(detailCount)")
                    print("📊 LocalFileEntity rows = \(fileCount)")
                    if distinctIds < itemCount {
                        print("⚠️ DUPLICATE ROWS DETECTED: \(itemCount - distinctIds) duplicates with same instanceId — @Attribute(.unique) is not being enforced")
                    }
                    let states = Dictionary(grouping: allItems, by: \.mbidScanState).mapValues(\.count)
                    print("📊 mbidScanState distribution: \(states)")
#endif
                    await checkForRestorePrompt()
                }
                .alert("Restore Matches from Backup?", isPresented: $showLaunchRestorePrompt) {
                    Button("Restore Now") {
                        Task { @MainActor in
                            await performLaunchRestore()
                        }
                    }
                    Button("Later", role: .cancel) { }
                } message: {
                    Text("No confident matches found in the current library, but a backup file with \(launchBackupEntries) entries was found. Restore from backup?")
                }
        }
        .modelContainer(container)
#if os(macOS)
        Settings {
            NavigationStack {
                SettingsView()
            }
            .environment(settingsViewModel)
            .environment(fileMatchCoordinator)
            .environment(fingerprintCoordinator)
            .environment(localAnalysisCoordinator)
        }
        .modelContainer(container)
#endif
    }

    @MainActor
    private func checkForRestorePrompt() async {
        let descriptor = FetchDescriptor<TrackEntity>(
            predicate: #Predicate { $0.fileMatchState == "confident" }
        )
        let ctx = container.mainContext
        guard let confidentCount = try? ctx.fetchCount(descriptor) else { return }
        guard confidentCount == 0 else { return }
        guard let backupURL = MatchesBackupService.storedBackupURL() else { return }
        guard let backup = try? MatchesBackupService.readBackup(from: backupURL) else { return }
        guard backup.totalEntries > 0 else { return }
        launchBackupURL = backupURL
        launchBackupEntries = backup.totalEntries
        showLaunchRestorePrompt = true
    }

    @MainActor
    private func performLaunchRestore() async {
        guard let url = launchBackupURL else { return }
        guard let backup = try? MatchesBackupService.readBackup(from: url) else { return }
        let ctx = container.mainContext
        do {
            let result = try MatchesBackupService.applyBackup(backup, modelContext: ctx)
            print("[RESTORE] Launch restore: \(result.restored) restored, \(result.skippedFileMissing) skipped (file missing), \(result.skippedTrackMissing) skipped (track missing)")
        } catch {
            print("[RESTORE] Launch restore failed: \(error.localizedDescription)")
        }
    }
}
