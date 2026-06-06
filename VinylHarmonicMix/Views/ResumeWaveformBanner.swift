import SwiftUI

struct ResumeWaveformBanner: View {
    @Environment(FileMatchCoordinator.self) private var coordinator
    @State private var isVisible = false
    @State private var pendingCount: Int = 0

    var body: some View {
        VStack(spacing: 0) {
            if isVisible {
                HStack(spacing: 12) {
                    Image(systemName: "waveform.path.badge.plus")
                        .foregroundStyle(Color.accentColor)
                        .font(.title3)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Waveform generation paused")
                            .font(.system(size: 13, weight: .semibold))
                        Text("\(pendingCount) tracks pending — resume to continue generating waveforms in the background.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button("Resume (\(pendingCount))") {
                        coordinator.resumeWaveformGenerationOnly()
                        withAnimation { isVisible = false }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

                    Button {
                        UserDefaults.standard.set(false, forKey: "VinylHarmonicMix.PendingWaveformGenerationPaused")
                        withAnimation { isVisible = false }
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .help("Dismiss")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.regularMaterial)
                .overlay(alignment: .bottom) { Divider() }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .task {
            guard FileMatchCoordinator.hasPendingWaveformGeneration() else { return }
            let count = coordinator.countPendingWaveforms()
            guard count > 0 else {
                UserDefaults.standard.set(false, forKey: "VinylHarmonicMix.PendingWaveformGenerationPaused")
                return
            }
            pendingCount = count
            withAnimation { isVisible = true }
        }
    }
}
