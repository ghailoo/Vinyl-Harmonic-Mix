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
                libraryBubble(title: "Sync",           icon: "arrow.triangle.2.circlepath") { syncOrchestrator.startSync() }
                libraryBubble(title: "MBID",           icon: "magnifyingglass.circle")       { scanCoordinator.start() }
                libraryBubble(title: "AcousticBrainz", icon: "waveform.circle")             { audioFeaturesCoordinator.start() }
                libraryBubble(title: "Match Audio",    icon: "link.circle")                 { fileMatchCoordinator.startFullScan() }
                libraryBubble(title: "Cues",           icon: "scope")                       { cueCoordinator.startDetection(scope: .matched) }
            }

            NowPlayingBar()
                .frame(maxWidth: .infinity)

            // Force @Observable tracking for all coordinator state we read in activeOperations
            let _ = syncOrchestrator.isSyncing
            let _ = syncOrchestrator.syncStatus
            let _ = scanCoordinator.scanned
            let _ = audioFeaturesCoordinator.batchesProcessed
            let _ = fileMatchCoordinator.phase
            let _ = fileMatchCoordinator.waveformsPausing
            let _ = cueCoordinator.phase

            HStack(spacing: 8) {
                ForEach(activeOperations, id: \.name) { status in
                    OperationStatusBubble(status: status)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var activeOperations: [OperationStatus] {
        var result: [OperationStatus] = []

        if syncOrchestrator.isSyncing {
            result.append(.simple(
                name: "Sync",
                icon: "arrow.triangle.2.circlepath",
                isRunning: true,
                statusText: syncOrchestrator.syncStatus.isEmpty ? nil : syncOrchestrator.syncStatus
            ))
        }

        if case .scanning = scanCoordinator.phase {
            result.append(.simple(
                name: "MBID Scan",
                icon: "magnifyingglass",
                isRunning: true,
                count: scanCoordinator.scanned,
                total: scanCoordinator.total
            ))
        }

        if case .scanning = audioFeaturesCoordinator.phase {
            result.append(.simple(
                name: "AcousticBrainz",
                icon: "waveform.circle",
                isRunning: true,
                count: audioFeaturesCoordinator.batchesProcessed,
                total: audioFeaturesCoordinator.batchesTotal
            ))
        }

        if let fileMatch = fileMatchStatus() {
            result.append(fileMatch)
        }

        if cueCoordinator.phase == .detecting {
            result.append(.simple(
                name: "Cue Detection",
                icon: "scope",
                isRunning: true,
                count: cueCoordinator.processedCount,
                total: cueCoordinator.totalCount
            ))
        }

        return result
    }

    private func fileMatchStatus() -> OperationStatus? {
        let c = fileMatchCoordinator
        switch c.phase {
        case .indexing:
            return .simple(name: "Match Audio", icon: "link", isRunning: true,
                           statusText: "Indexing… \(c.indexedCount)")
        case .matching:
            return .simple(name: "Match Audio", icon: "link", isRunning: true,
                           count: c.processedTracks, total: c.totalTracks)
        case .generatingWaveforms, .generatingWaveformsPaused:
            return OperationStatus(
                name: "Waveforms",
                icon: "waveform",
                isRunning: true,
                count: c.waveformsGenerated,
                total: c.waveformsTotal,
                statusText: nil,
                pauseAction: { c.pauseWaveformGeneration() },
                resumeAction: { c.resumeWaveformGeneration() },
                isPaused: c.phase == .generatingWaveformsPaused,
                isPausing: c.waveformsPausing
            )
        default:
            return nil
        }
    }

    private func bubbleColor(for title: String) -> Color {
        switch title {
        case "Sync":           return .blue
        case "MBID":           return .purple
        case "AcousticBrainz": return .teal
        case "Match Audio":    return .orange
        case "Cues":           return .pink
        default:               return .accentColor
        }
    }

    @ViewBuilder
    private func libraryBubble(title: String, icon: String, action: @escaping () -> Void) -> some View {
        let tint = bubbleColor(for: title)
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
                Text(title)
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(tint.opacity(0.15))
                    .overlay(
                        Capsule()
                            .stroke(tint.opacity(0.4), lineWidth: 0.5)
                    )
            )
        }
        .buttonStyle(LibraryBubbleButtonStyle(tint: tint))
        .help(title)
    }
}

struct LibraryBubbleButtonStyle: ButtonStyle {
    let tint: Color
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                Capsule()
                    .fill(isHovering ? tint.opacity(0.22) : Color.clear)
                    .animation(.easeInOut(duration: 0.15), value: isHovering)
            )
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
            .onHover { hovering in
                isHovering = hovering
            }
    }
}
