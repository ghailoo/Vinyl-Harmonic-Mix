import SwiftUI

struct UnifiedTopBar: View {
    @Environment(SyncOrchestrator.self) private var syncOrchestrator
    @Environment(MBIDScanCoordinator.self) private var scanCoordinator
    @Environment(AudioFeaturesScanCoordinator.self) private var audioFeaturesCoordinator
    @Environment(FileMatchCoordinator.self) private var fileMatchCoordinator
    @Environment(CueDetectionCoordinator.self) private var cueCoordinator

    var body: some View {
        HStack(spacing: 16) {
            HStack(spacing: 8) {
                libraryBubble(title: "Sync",          icon: "arrow.triangle.2.circlepath") { syncOrchestrator.startSync() }
                libraryBubble(title: "MBID",          icon: "magnifyingglass.circle")       { scanCoordinator.start() }
                libraryBubble(title: "AcousticBrainz",icon: "waveform.circle")             { audioFeaturesCoordinator.start() }
                libraryBubble(title: "Match Audio",   icon: "link.circle")                 { fileMatchCoordinator.startFullScan() }
                libraryBubble(title: "Cues",          icon: "scope")                       { cueCoordinator.startDetection(scope: .matched) }
            }

            NowPlayingBar()
                .frame(maxWidth: .infinity)

            WaveformStatusBubble()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) { Divider() }
    }

    @ViewBuilder
    private func libraryBubble(title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
                Text(title)
                    .font(.system(size: 12, weight: .medium))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(.regularMaterial)
                    .overlay(Capsule().stroke(Color.primary.opacity(0.08), lineWidth: 0.5))
            )
        }
        .buttonStyle(.plain)
        .help(title)
    }
}

struct WaveformStatusBubble: View {
    @Environment(FileMatchCoordinator.self) private var coordinator
    @State private var pendingCount: Int = 0

    var body: some View {
        let _ = coordinator.phase  // force @Observable tracking in body

        Group {
            if shouldShow {
                HStack(spacing: 8) {
                    progressContent
                    actionButton
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    Capsule()
                        .fill(Color.accentColor.opacity(0.12))
                        .overlay(Capsule().stroke(Color.accentColor.opacity(0.3), lineWidth: 0.5))
                )
            }
        }
        .task(id: coordinator.phase) {
            pendingCount = coordinator.countPendingWaveforms()
        }
        .task {
            pendingCount = coordinator.countPendingWaveforms()
        }
    }

    private var shouldShow: Bool {
        if coordinator.phase == .generatingWaveforms { return true }
        if coordinator.phase == .generatingWaveformsPaused { return true }
        return FileMatchCoordinator.hasPendingWaveformGeneration() && pendingCount > 0
    }

    @ViewBuilder
    private var progressContent: some View {
        switch coordinator.phase {
        case .generatingWaveforms, .generatingWaveformsPaused:
            HStack(spacing: 6) {
                Image(systemName: coordinator.phase == .generatingWaveformsPaused ? "pause.circle.fill" : "waveform")
                    .font(.system(size: 12, weight: .medium))
                Text("\(coordinator.waveformsGenerated) / \(coordinator.waveformsTotal)")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
            }
        default:
            HStack(spacing: 6) {
                Image(systemName: "waveform.path.badge.plus")
                    .font(.system(size: 12, weight: .medium))
                Text("\(pendingCount) pending")
                    .font(.system(size: 11, weight: .medium))
            }
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        if coordinator.phase == .generatingWaveforms && !coordinator.waveformsPausing {
            Button { coordinator.pauseWaveformGeneration() } label: {
                Image(systemName: "pause.fill").font(.system(size: 10, weight: .bold))
            }
            .buttonStyle(.plain)
            .help("Pause waveform generation")
        } else if coordinator.phase == .generatingWaveforms && coordinator.waveformsPausing {
            Image(systemName: "ellipsis")
                .font(.system(size: 10, weight: .bold))
                .opacity(0.5)
        } else if coordinator.phase == .generatingWaveformsPaused {
            Button { coordinator.resumeWaveformGeneration() } label: {
                Image(systemName: "play.fill").font(.system(size: 10, weight: .bold))
            }
            .buttonStyle(.plain)
            .help("Resume waveform generation")
        } else {
            Button { coordinator.resumeWaveformGenerationOnly() } label: {
                Image(systemName: "play.fill").font(.system(size: 10, weight: .bold))
            }
            .buttonStyle(.plain)
            .help("Resume waveform generation")
        }
    }
}
