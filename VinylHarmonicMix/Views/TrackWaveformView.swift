import SwiftUI

struct TrackWaveformView: View {
    @Environment(AudioPlaybackController.self) private var playback
    let filePath: String

    var body: some View {
        let isActive = playback.currentFilePath == filePath
        let progress: Double = isActive && playback.duration > 0
            ? min(1, max(0, playback.currentTime / playback.duration))
            : 0.0

        VStack(alignment: .leading, spacing: 4) {
            switch playback.waveformState(for: filePath) {
            case .ready(let peaks):
                WaveformView(peaks: peaks, progress: progress) { fraction in
                    guard playback.currentFilePath == filePath else { return }
                    playback.seek(toFraction: fraction)
                }
                .clipShape(RoundedRectangle(cornerRadius: 4))
            case .loading:
                ZStack {
                    RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.1))
                    HStack(spacing: 6) {
                        ProgressView().scaleEffect(0.6)
                        Text("Loading waveform…").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            case .failed:
                ZStack {
                    RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.08))
                    Text("Waveform unavailable").font(.caption2).foregroundStyle(.tertiary)
                }
            case .idle:
                Color.clear
                    .onAppear { playback.loadWaveformIfNeeded(filePath: filePath) }
            }

            if isActive && playback.duration > 0 {
                Text("\(formatTime(playback.currentTime)) / \(formatTime(playback.duration))")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .frame(height: 68)
    }

    private func formatTime(_ seconds: Double) -> String {
        let s = max(0, Int(seconds))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
