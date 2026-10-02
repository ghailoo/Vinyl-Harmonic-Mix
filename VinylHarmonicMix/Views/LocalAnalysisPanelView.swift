import SwiftUI

struct LocalAnalysisPanelView: View {
    let coordinator: LocalAnalysisCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                phaseIcon
                Text(phaseLabel)
                    .font(.body.weight(.semibold))
                Spacer()
            }

            if !coordinator.currentTrackLabel.isEmpty {
                Text(coordinator.currentTrackLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            if coordinator.totalCount > 0 {
                HStack(spacing: 16) {
                    countBadge(label: "Analyzed", count: coordinator.analyzedCount, color: .green)
                    countBadge(label: "Failed",   count: coordinator.failedCount,   color: .secondary)
                }

                if coordinator.phase == .analyzing || coordinator.phase == .paused {
                    ProgressView(value: Double(coordinator.analyzedCount),
                                 total: Double(coordinator.totalCount))
                    Text("\(coordinator.analyzedCount) / \(coordinator.totalCount) tracks")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }

            if let err = coordinator.lastError {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red).font(.caption)
            }

            HStack(spacing: 8) {
                if coordinator.phase == .analyzing {
                    Button("Pause") { coordinator.pause() }.controlSize(.small)
                }
                if coordinator.phase == .paused {
                    Button("Resume") { coordinator.resume() }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                }
                if coordinator.phase == .analyzing || coordinator.phase == .paused {
                    Button("Cancel") { coordinator.cancel() }
                        .controlSize(.small).foregroundStyle(.red)
                }
                if coordinator.phase.isIdle {
                    Button("Dismiss") { coordinator.dismissPanel() }.controlSize(.small)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private var phaseIcon: some View {
        switch coordinator.phase {
        case .completed:      Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .cancelled:      Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        case .paused:         Image(systemName: "pause.circle.fill").foregroundStyle(.orange)
        case .failed(let m):  Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
            .help(m)
            .accessibilityLabel(m)
        default:              ProgressView().controlSize(.small)
        }
    }

    private var phaseLabel: String {
        switch coordinator.phase {
        case .idle:         return "Idle"
        case .analyzing:    return "Analyzing tracks…"
        case .paused:       return "Paused"
        case .completed:    return "Analysis complete"
        case .cancelled:    return "Cancelled"
        case .failed(let m): return "Failed: \(m)"
        }
    }

    private func countBadge(label: String, count: Int, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(count.formatted())
                .font(.title3.weight(.bold).monospacedDigit())
                .foregroundStyle(count > 0 ? color : Color.secondary.opacity(0.5))
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }
}
