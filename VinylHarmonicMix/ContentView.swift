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
            VStack(spacing: 0) {
                NowPlayingBar()
                Divider()
                Group {
                    switch sidebarSelection {
                    case .stats:
                        CollectionStatsView()
                    case .fileMatches:
                        FileMatchesView()
                    default:
                        CollectionGridView()
                    }
                }
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

// MARK: - Global now-playing bar (always visible across all tabs)

#if os(macOS)
private struct NowPlayingBar: View {
    @Environment(AudioPlaybackController.self) private var playback

    var body: some View {
        HStack(spacing: 10) {
            if let path = playback.currentFilePath {
                // Play / Pause
                Button {
                    playback.play(filePath: path)
                } label: {
                    Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 12)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                .help(playback.isPlaying ? "Pause" : "Resume")

                // Stop
                Button {
                    playback.stop()
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Stop")

                Divider().frame(height: 14)

                // Track label + time
                VStack(alignment: .leading, spacing: 0) {
                    Text(URL(fileURLWithPath: path).lastPathComponent)
                        .font(.system(size: 11))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 240, alignment: .leading)
                    if playback.duration > 0 {
                        Text("\(formatTime(playback.currentTime)) / \(formatTime(playback.duration))")
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()

            // Volume — always visible so the user can set level before playback
            HStack(spacing: 4) {
                Image(systemName: "speaker.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Slider(
                    value: Binding(
                        get: { playback.volume },
                        set: { playback.volume = $0 }
                    ),
                    in: 0...1
                )
                .frame(width: 80)
                .controlSize(.mini)
                Image(systemName: "speaker.wave.3.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 36)
    }

    private func formatTime(_ seconds: Double) -> String {
        let s = max(0, Int(seconds))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
#endif

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
