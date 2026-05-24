import SwiftUI

struct CueDetectionPanel: View {
    let coordinator: CueDetectionCoordinator

    var body: some View {
        HStack(spacing: 16) {
            if coordinator.phase == .detecting {
                ProgressView()
                    .controlSize(.small)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text("Cue detection")
                        .font(.system(size: 13, weight: .semibold))
                    if coordinator.totalCount > 0 {
                        Text("\(coordinator.processedCount) / \(coordinator.totalCount)")
                            .font(.system(size: 12).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    if coordinator.detectedCount > 0 {
                        Text("✓ \(coordinator.detectedCount)")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.green)
                    }
                    if coordinator.skippedCount > 0 {
                        Text("— \(coordinator.skippedCount) no intro")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    if coordinator.failedCount > 0 {
                        Text("✗ \(coordinator.failedCount)")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.red)
                    }
                }
                if !coordinator.currentFileLabel.isEmpty {
                    Text(coordinator.currentFileLabel)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer()

            HStack(spacing: 8) {
                switch coordinator.phase {
                case .detecting:
                    Button("Pause") { coordinator.pause() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                case .paused:
                    Button("Resume") { coordinator.resume() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    Button("Cancel") { coordinator.cancel() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(.red)
                case .completed:
                    Text("Done")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    Button("Dismiss") { coordinator.dismissPanel() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                case .cancelled:
                    Button("Dismiss") { coordinator.dismissPanel() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                default:
                    EmptyView()
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(0.15), lineWidth: 0.5))
    }
}
