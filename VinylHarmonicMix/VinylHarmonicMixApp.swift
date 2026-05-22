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
    @State private var audioPlaybackController: AudioPlaybackController

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
            ])
            // Sandbox is disabled so the default store path moves to ~/Library/Application Support/.
            // Pin to the container path so existing Discogs/MusicBrainz data is preserved
            // regardless of sandbox state. SwiftData will auto-migrate the schema on first open.
            let bundleID = Bundle.main.bundleIdentifier ?? "VinylHarmonicMix"
            let containerStoreURL = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Containers/\(bundleID)/Data/Library/Application Support/default.store")
            let config = ModelConfiguration(url: containerStoreURL)
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

        _collectionViewModel = State(initialValue: CollectionViewModel(context: ctx))
        _scanCoordinator = State(initialValue: MBIDScanCoordinator(context: ctx))
        _cacheCoordinator = State(initialValue: DetailCacheCoordinator(context: ctx))
        _recordingsCoordinator = State(initialValue: RecordingsScanCoordinator(context: ctx))
        _audioFeaturesCoordinator = State(initialValue: AudioFeaturesScanCoordinator(context: ctx))
        _fileMatchCoordinator = State(initialValue: FileMatchCoordinator(context: ctx))
        _fingerprintCoordinator = State(initialValue: FingerprintScanCoordinator(context: ctx))
        _localAnalysisCoordinator = State(initialValue: LocalAnalysisCoordinator(context: ctx))
        _audioPlaybackController = State(initialValue: AudioPlaybackController())
#if DEBUG
        Task { @MainActor in
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
        }
#endif
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
                .environment(audioPlaybackController)
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
#endif
    }
}
