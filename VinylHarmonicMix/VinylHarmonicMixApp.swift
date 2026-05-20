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
            ])
            container = try ModelContainer(for: schema)
        } catch {
            fatalError("SwiftData container init failed: \(error)")
        }
        let ctx = container.mainContext
        _collectionViewModel = State(initialValue: CollectionViewModel(context: ctx))
        _scanCoordinator = State(initialValue: MBIDScanCoordinator(context: ctx))
        _cacheCoordinator = State(initialValue: DetailCacheCoordinator(context: ctx))
        _recordingsCoordinator = State(initialValue: RecordingsScanCoordinator(context: ctx))
        _audioFeaturesCoordinator = State(initialValue: AudioFeaturesScanCoordinator(context: ctx))
        _fileMatchCoordinator = State(initialValue: FileMatchCoordinator(context: ctx))
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
        }
        .modelContainer(container)
#if os(macOS)
        Settings {
            NavigationStack {
                SettingsView()
            }
            .environment(settingsViewModel)
            .environment(fileMatchCoordinator)
        }
#endif
    }
}
