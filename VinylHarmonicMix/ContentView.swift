import SwiftUI

enum SidebarItem: String, Hashable {
    case collection  = "Collection"
    case stats       = "Stats"
    case fileMatches = "File Matches"
}

struct ContentView: View {
    @Environment(SettingsViewModel.self) private var settings
    @Environment(CollectionViewModel.self) private var collection
    @State private var showSettings = false
    @State private var sidebarSelection: SidebarItem? = .collection

    var body: some View {
#if os(macOS)
        NavigationSplitView {
            macSidebar
        } detail: {
            switch sidebarSelection {
            case .stats:
                CollectionStatsView()
            case .fileMatches:
                FileMatchesView()
            default:
                CollectionGridView()
            }
        }
#else
        NavigationStack {
            CollectionGridView()
                .onAppear { collection.refreshConfiguration() }
                .navigationTitle("VinylHarmonicMix")
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        NavigationLink {
                            SettingsView()
                        } label: {
                            Label("Settings", systemImage: "gear")
                        }
                    }
                }
        }
#endif
    }

#if os(macOS)
    private var macSidebar: some View {
        List(selection: $sidebarSelection) {
            Label("Collection", systemImage: "record.circle")
                .tag(SidebarItem.collection)
            Label("Stats", systemImage: "chart.bar.xaxis")
                .tag(SidebarItem.stats)
            Label("File Matches", systemImage: "waveform.and.magnifyingglass")
                .tag(SidebarItem.fileMatches)
            Divider()
            Button(action: { showSettings = true }) {
                Label("Settings", systemImage: "gear")
            }
            .buttonStyle(.plain)
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 180, ideal: 220)
        .navigationTitle("VinylHarmonicMix")
        .sheet(isPresented: $showSettings, onDismiss: {
            collection.refreshConfiguration()
        }) {
            NavigationStack { SettingsView() }
                .environment(settings)
                .frame(minWidth: 440, minHeight: 340)
        }
    }
#endif
}
