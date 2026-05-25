import SwiftUI
import SwiftData

struct TrackWaveformView: View {
    @Environment(AudioPlaybackController.self) private var playback
    @Environment(\.modelContext) private var modelContext
    let filePath: String

    @State private var cueMarkers: [CueMarker] = []
    @State private var fileDuration: Double = 0

    var body: some View {
        let isActive         = playback.currentFilePath == filePath
        let playbackDuration = isActive ? playback.duration : 0.0
        let progress: Double = playbackDuration > 0
            ? min(1, max(0, playback.currentTime / playbackDuration))
            : 0.0
        // Use live playback duration when playing; fall back to DB durationMs when idle
        let duration = playbackDuration > 0 ? playbackDuration : fileDuration

        VStack(alignment: .leading, spacing: 4) {
            switch playback.waveformState(for: filePath) {
            case .ready(let peaks):
                WaveformView(
                    peaks: peaks,
                    progress: progress,
                    cueMarkers: cueMarkers,
                    duration: duration
                ) { fraction in
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

            if isActive && playbackDuration > 0 {
                Text("\(formatTime(playback.currentTime)) / \(formatTime(playbackDuration))")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .frame(height: 68)
        .task(id: filePath) { loadCueData() }
    }

    // Fetch cue times + durationMs from the LocalFileEntity for this file.
    // Runs synchronously on the main actor; safe because modelContext is main-actor isolated.
    private func loadCueData() {
        let fp = filePath
        var fd = FetchDescriptor<LocalFileEntity>(
            predicate: #Predicate { $0.filePath == fp }
        )
        fd.fetchLimit = 1
        guard let file = try? modelContext.fetch(fd).first else { return }
        cueMarkers   = file.cuePoints
            .map { CueMarker(timeSec: $0.timeSec, type: $0.type,
                             energyDirection: $0.energyDirection, energyDelta: $0.energyDelta) }
            .sorted { $0.timeSec < $1.timeSec }
        fileDuration = file.durationMs > 0 ? Double(file.durationMs) / 1000.0 : 0
    }

    private func formatTime(_ seconds: Double) -> String {
        let s = max(0, Int(seconds))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
