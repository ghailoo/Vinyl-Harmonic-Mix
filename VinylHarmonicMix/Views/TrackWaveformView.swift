import SwiftUI
import SwiftData

struct TrackWaveformView: View {
    @Environment(AudioPlaybackController.self) private var playback
    @Environment(\.modelContext) private var modelContext
    let filePath: String
    @Binding var zoomFactor: Double

    @State private var cueMarkers: [CueMarker] = []
    @State private var fileDuration: Double = 0
    @State private var fileEntity: LocalFileEntity? = nil
    @State private var viewportWidth: CGFloat = 0

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
                                },
                                onMoveCue: { old, new in
                                    moveCue(oldTimeSec: old, newTimeSec: new)
                                }
                            )
                            .equatable()
                            .frame(width: canvasWidth > 0 ? canvasWidth : nil, height: 80)
                            .clipShape(RoundedRectangle(cornerRadius: 4))

                            // Invisible anchor for scroll-to-playhead.
                            // Only created when zoomed — avoids per-tick layout work at 1×.
                            if zoomFactor > 1, canvasWidth > 0 {
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
                        .frame(width: canvasWidth > 0 ? canvasWidth : nil, height: 80)
                    }
                    // Playhead line rendered in viewport coordinates.
                    // MODE 1 (zoom==1): line moves at viewportWidth × progress across the fixed canvas.
                    // MODE 2 (zoom>1): line is pinned to viewport centre; waveform scrolls under it.
                    .overlay(alignment: .leading) {
                        if isActive && viewportWidth > 0 {
                            let lineX: CGFloat = zoomFactor <= 1
                                ? viewportWidth * CGFloat(progress)
                                : viewportWidth / 2
                            Rectangle()
                                .fill(Color.white.opacity(0.9))
                                .frame(width: 2.5)
                                .offset(x: lineX - 1.25)
                                .allowsHitTesting(false)
                        }
                    }
                    // Zoom>1: scroll fires every timer tick (no bucket throttle) so the waveform
                    // tracks the fixed centre line in real time. withAnimation(.none) = instant jump.
                    .onChange(of: progress) { _, _ in
                        guard isActive && playback.isPlaying && zoomFactor > 1 else { return }
                        withAnimation(.none) {
                            proxy.scrollTo("waveformPlayhead", anchor: .center)
                        }
                    }
                    // On zoom-in: immediately centre the playhead in the new zoomed viewport.
                    .onChange(of: zoomFactor) { _, newZoom in
                        guard newZoom > 1 else { return }
                        withAnimation(.none) {
                            proxy.scrollTo("waveformPlayhead", anchor: .center)
                        }
                    }
                    // Deck switch: deferred one runloop so SwiftUI commits the updated
                    // progress layout before scrollTo resolves the anchor position.
                    .onChange(of: isActive) { _, active in
                        guard active && zoomFactor > 1 else { return }
                        Task { @MainActor in
                            withAnimation(.none) {
                                proxy.scrollTo("waveformPlayhead", anchor: .center)
                            }
                        }
                    }
                }

            case .loading:
                ZStack {
                    RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.1))
                    HStack(spacing: 6) {
                        ProgressView().scaleEffect(0.6)
                        Text("Loading waveform…").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .frame(height: 80)
            case .failed:
                ZStack {
                    RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.08))
                    Text("Waveform unavailable").font(.caption2).foregroundStyle(.tertiary)
                }
                .frame(height: 80)
            case .idle:
                Color.clear
                    .frame(height: 80)
                    .onAppear { playback.loadWaveformIfNeeded(filePath: filePath) }
            }

            Text(isActive && playbackDuration > 0
                ? "\(formatTime(playback.currentTime)) / \(formatTime(playbackDuration))"
                : " ")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .frame(height: 100)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { w in
            if w > 0 { viewportWidth = w }
        }
        .task(id: filePath) { loadCueData() }
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
    //
    // All three follow the same pattern:
    //   1. Mutate main-context in-memory (fast, no I/O) so file.cuePoints stays correct.
    //   2. Update cueMarkers view array for instant UI.
    //   3. Persist via Task.detached on a fresh background ModelContext — WAL checkpoint
    //      (the slow part) happens entirely off the main thread.
    //
    // Only PersistentIdentifier, ModelContainer, and value types cross the task boundary.
    // @Model objects are never passed across — re-fetched inside the background context.

    private func addManualCue(fraction: Double, type: String,
                               energyDirection: String, duration: Double) {
        // Capture file's stable ID before entering the background task.
        guard let fileID = fileEntity?.persistentModelID, duration > 0 else { return }
        let timeSec   = fraction * duration
        let createdAt = Date.now

        // Instant UI — no main-context changes needed for add (merge delivers the entity later).
        cueMarkers.append(CueMarker(timeSec: timeSec, type: type,
                                    energyDirection: energyDirection,
                                    energyDelta: 0.0, isManual: true))
        cueMarkers.sort { $0.timeSec < $1.timeSec }

        // Insert + save on background context. Main thread never touches disk.
        let container = modelContext.container
        Task.detached(priority: .utility) {
            let ctx = ModelContext(container)
            guard let file = ctx.model(for: fileID) as? LocalFileEntity else { return }
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
            cue.createdAt       = createdAt
            cue.localFile       = file
            ctx.insert(cue)
            try? ctx.save()
        }
    }

    private func deleteManualCue(timeSec: Double) {
        guard let file = fileEntity else { return }
        cueMarkers.removeAll { abs($0.timeSec - timeSec) < 0.01 }
        guard let match = file.cuePoints.first(where: { abs($0.timeSec - timeSec) < 0.01 }) else { return }

        // Capture ID before deletion so the background context can re-fetch it.
        let id = match.persistentModelID
        // Remove from main context in-memory so file.cuePoints is immediately clean.
        modelContext.delete(match)

        // Delete + save on background context.
        let container = modelContext.container
        Task.detached(priority: .utility) {
            let ctx = ModelContext(container)
            if let entity = ctx.model(for: id) as? CuePointEntity {
                ctx.delete(entity)
                try? ctx.save()
            }
        }
    }

    private func moveCue(oldTimeSec: Double, newTimeSec: Double) {
        guard let file = fileEntity,
              let entity = file.cuePoints.first(where: { abs($0.timeSec - oldTimeSec) < 0.01 })
        else { return }

        // Mutate on main context in-memory so rapid re-drags find the updated timeSec.
        entity.timeSec = newTimeSec
        entity.isManual = true
        let id = entity.persistentModelID

        // Update view array.
        if let idx = cueMarkers.firstIndex(where: { abs($0.timeSec - oldTimeSec) < 0.01 }) {
            let old = cueMarkers[idx]
            cueMarkers[idx] = CueMarker(timeSec: newTimeSec, type: old.type,
                                         energyDirection: old.energyDirection,
                                         energyDelta: old.energyDelta, isManual: true)
            cueMarkers.sort { $0.timeSec < $1.timeSec }
        }

        // Persist on background context.
        let container = modelContext.container
        Task.detached(priority: .utility) {
            let ctx = ModelContext(container)
            if let e = ctx.model(for: id) as? CuePointEntity {
                e.timeSec   = newTimeSec
                e.isManual  = true
                try? ctx.save()
            }
        }
    }

    private func formatTime(_ seconds: Double) -> String {
        let s = max(0, Int(seconds))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
