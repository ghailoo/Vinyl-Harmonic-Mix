import SwiftUI
import SwiftData

struct TrackWaveformView: View {
    @Environment(AudioPlaybackController.self) private var playback
    @Environment(\.modelContext) private var modelContext
    let filePath: String

    @State private var cueMarkers: [CueMarker] = []
    @State private var fileDuration: Double = 0
    @State private var fileEntity: LocalFileEntity? = nil
    @State private var zoomFactor: Double = 1.0
    @State private var viewportWidth: CGFloat = 0

    // Zoomed canvas width; 0 until the outer geometry fires on first layout.
    private var canvasWidth: CGFloat {
        viewportWidth > 0 ? viewportWidth * zoomFactor : 0
    }

    var body: some View {
        let isActive         = playback.currentFilePath == filePath
        let playbackDuration = isActive ? playback.duration : 0.0
        let progress: Double = playbackDuration > 0
            ? min(1, max(0, playback.currentTime / playbackDuration))
            : 0.0
        let duration = playbackDuration > 0 ? playbackDuration : fileDuration

        VStack(alignment: .leading, spacing: 4) {
            switch playback.waveformState(for: filePath) {
            case .ready(let peaks):
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: zoomFactor > 1) {
                        ZStack(alignment: .topLeading) {
                            WaveformView(
                                peaks: peaks,
                                progress: progress,
                                cueMarkers: cueMarkers,
                                duration: duration,
                                onSeek: { fraction in
                                    guard playback.currentFilePath == filePath else { return }
                                    playback.seek(toFraction: fraction)
                                },
                                onAddCue: { fraction, type, dir in
                                    addManualCue(fraction: fraction, type: type,
                                                 energyDirection: dir, duration: duration)
                                },
                                onDeleteCue: { ts in
                                    deleteManualCue(timeSec: ts)
                                }
                            )
                            .frame(width: canvasWidth > 0 ? canvasWidth : nil, height: 50)
                            .clipShape(RoundedRectangle(cornerRadius: 4))

                            // Invisible 1-px anchor positioned at the playhead —
                            // used by scrollTo to keep the playhead centred while playing.
                            if canvasWidth > 0 {
                                HStack(spacing: 0) {
                                    Color.clear
                                        .frame(width: max(0, canvasWidth * CGFloat(progress) - 1),
                                               height: 1)
                                    Color.clear.frame(width: 1, height: 1)
                                        .id("waveformPlayhead")
                                    Spacer(minLength: 0)
                                }
                                .frame(width: canvasWidth, height: 1)
                            }
                        }
                        .frame(width: canvasWidth > 0 ? canvasWidth : nil, height: 50)
                    }
                    .onChange(of: progress) { _, p in
                        guard isActive && playback.isPlaying && zoomFactor > 1 else { return }
                        proxy.scrollTo("waveformPlayhead", anchor: .center)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    zoomControls
                }

            case .loading:
                ZStack {
                    RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.1))
                    HStack(spacing: 6) {
                        ProgressView().scaleEffect(0.6)
                        Text("Loading waveform…").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .frame(height: 50)
            case .failed:
                ZStack {
                    RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.08))
                    Text("Waveform unavailable").font(.caption2).foregroundStyle(.tertiary)
                }
                .frame(height: 50)
            case .idle:
                Color.clear
                    .frame(height: 50)
                    .onAppear { playback.loadWaveformIfNeeded(filePath: filePath) }
            }

            if isActive && playbackDuration > 0 {
                Text("\(formatTime(playback.currentTime)) / \(formatTime(playbackDuration))")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .frame(height: 68)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { w in
            if w > 0 { viewportWidth = w }
        }
        .task(id: filePath) { loadCueData() }
    }

    // MARK: - Zoom controls

    private var zoomControls: some View {
        HStack(spacing: 4) {
            Button {
                zoomFactor = max(1, zoomFactor / 2)
            } label: {
                Image(systemName: "minus")
                    .font(.system(size: 9, weight: .semibold))
            }
            if zoomFactor > 1 {
                Text("\(Int(zoomFactor))×")
                    .font(.system(size: 9, weight: .medium).monospacedDigit())
            }
            Button {
                zoomFactor = min(8, zoomFactor * 2)
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 9, weight: .semibold))
            }
        }
        .foregroundStyle(Color.secondary.opacity(0.7))
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.black.opacity(0.35)))
        .padding(4)
        .buttonStyle(.plain)
    }

    // MARK: - Data loading

    private func loadCueData() {
        let fp = filePath
        var fd = FetchDescriptor<LocalFileEntity>(
            predicate: #Predicate { $0.filePath == fp }
        )
        fd.fetchLimit = 1
        guard let file = try? modelContext.fetch(fd).first else { return }
        fileEntity   = file
        cueMarkers   = file.cuePoints
            .map { CueMarker(timeSec: $0.timeSec, type: $0.type,
                             energyDirection: $0.energyDirection, energyDelta: $0.energyDelta,
                             isManual: $0.isManual) }
            .sorted { $0.timeSec < $1.timeSec }
        fileDuration = file.durationMs > 0 ? Double(file.durationMs) / 1000.0 : 0
    }

    // MARK: - Manual cue mutations

    private func addManualCue(fraction: Double, type: String,
                               energyDirection: String, duration: Double) {
        guard let file = fileEntity, duration > 0 else { return }
        let timeSec = fraction * duration
        let cue = CuePointEntity()
        cue.timeSec         = timeSec
        cue.feature         = "manual"
        cue.novelty         = 1.0
        cue.beatIndex       = 0
        cue.type            = type
        cue.energyDirection = energyDirection
        cue.energyDelta     = 0.0
        cue.source          = "manual"
        cue.isManual        = true
        cue.createdAt       = .now
        cue.localFile       = file
        modelContext.insert(cue)
        try? modelContext.save()
        cueMarkers.append(CueMarker(timeSec: timeSec, type: type,
                                    energyDirection: energyDirection,
                                    energyDelta: 0.0, isManual: true))
        cueMarkers.sort { $0.timeSec < $1.timeSec }
    }

    private func deleteManualCue(timeSec: Double) {
        guard let file = fileEntity else { return }
        cueMarkers.removeAll { abs($0.timeSec - timeSec) < 0.01 }
        if let match = file.cuePoints.first(where: { abs($0.timeSec - timeSec) < 0.01 }) {
            modelContext.delete(match)
            try? modelContext.save()
        }
    }

    private func formatTime(_ seconds: Double) -> String {
        let s = max(0, Int(seconds))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
