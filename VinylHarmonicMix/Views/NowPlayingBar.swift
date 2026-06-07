import SwiftUI
import SwiftData

struct NowPlayingBar: View {
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
