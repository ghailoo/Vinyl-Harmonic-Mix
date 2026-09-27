import SwiftUI
import SwiftData

struct NowPlayingBar: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(AudioPlaybackController.self) private var playback
    @Environment(\.modelContext) private var modelContext
    @State private var coverArtURL: URL? = nil

    var body: some View {
        HStack(spacing: 10) {
            SpinningRecordView(
                isPlaying: playback.isPlaying,
                coverArtURL: coverArtURL,
                diameter: 28
            )
            .opacity(playback.currentFilePath != nil ? 1 : 0)

            if let path = playback.currentFilePath {
                if !playback.playingSetItems.isEmpty {
                    Button {
                        playback.previousTrack()
                    } label: {
                        Image(systemName: "backward.end.fill")
                            .font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .disabled(playback.playingSetIndex == 0)
                    .help("Previous track in set")
                    .accessibilityLabel("Previous track in set")
                }

                Button {
                    playback.skipBackward10()
                } label: {
                    Image(systemName: "gobackward.10")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.plain)
                .help("Skip back 10 seconds")
                .accessibilityLabel("Skip back 10 seconds")

                Button {
                    playback.play(filePath: path)
                } label: {
                    Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                        .font(.subheadline.weight(.semibold))
                        .frame(width: 12)
                        .contentTransition(reduceMotion ? .opacity : .symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                .help(playback.isPlaying ? "Pause" : "Resume")
                .accessibilityLabel(playback.isPlaying ? "Pause" : "Resume")

                Button {
                    playback.stop()
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Stop")
                .accessibilityLabel("Stop")

                Button {
                    playback.skipForward10()
                } label: {
                    Image(systemName: "goforward.10")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.plain)
                .help("Skip forward 10 seconds")
                .accessibilityLabel("Skip forward 10 seconds")

                if !playback.playingSetItems.isEmpty || playback.isSmartExtensionActive {
                    Button {
                        playback.nextTrack()
                    } label: {
                        Image(systemName: "forward.end.fill")
                            .font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .disabled(
                        playback.isSmartExtensionActive
                            ? false
                            : playback.playingSetIndex >= playback.playingSetItems.count - 1
                    )
                    .help(playback.isSmartExtensionActive ? "Skip to next harmonic match" : "Next track in set")
                    .accessibilityLabel(playback.isSmartExtensionActive ? "Skip to next harmonic match" : "Next track in set")
                }

                Divider().frame(height: 14)

                VStack(alignment: .leading, spacing: 0) {
                    Text(URL(fileURLWithPath: path).lastPathComponent)
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 240, alignment: .leading)
                    if playback.isSmartExtensionActive {
                        HStack(spacing: 4) {
                            Image(systemName: "waveform.path")
                                .font(.caption)
                            Text("⇝ Library")
                                .font(.callout)
                        }
                        .foregroundStyle(.secondary)
                    } else if playback.duration > 0 {
                        Text("\(formatTime(playback.currentTime)) / \(formatTime(playback.duration))")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()

            HStack(spacing: 4) {
                Image(systemName: "speaker.fill")
                    .font(.caption)
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
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 36)
        .task(id: playback.currentFilePath) {
            coverArtURL = resolveCoverArt(for: playback.currentFilePath)
        }
    }

    private func resolveCoverArt(for filePath: String?) -> URL? {
        guard let filePath else { return nil }
        var descriptor = FetchDescriptor<TrackEntity>(
            predicate: #Predicate { $0.primaryLocalFilePath == filePath }
        )
        descriptor.fetchLimit = 1
        guard let track = try? modelContext.fetch(descriptor).first,
              let thumb = track.collectionItem?.basicInformation?.thumb,
              !thumb.isEmpty else { return nil }
        return URL(string: thumb)
    }

    private func formatTime(_ seconds: Double) -> String {
        let s = max(0, Int(seconds))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
