import SwiftUI

struct FileMatchPanelView: View {
    let coordinator: FileMatchCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                phaseIcon
                Text(phaseLabel)
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
            }

            if !coordinator.currentTrackLabel.isEmpty {
                Text(coordinator.currentTrackLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            if coordinator.phase == .confirming || coordinator.phase == .completed {
                HStack(spacing: 16) {
                    countBadge(label: "Matched", count: coordinator.matchedCount, color: .green)
                    countBadge(label: "Unconfirmed", count: coordinator.unconfirmedCount, color: .orange)
                    countBadge(label: "No file", count: coordinator.noCandidateCount, color: .secondary)
                }

                if coordinator.totalTracks > 0 && coordinator.phase == .confirming {
                    ProgressView(value: Double(coordinator.processedTracks),
                                 total: Double(coordinator.totalTracks))
                    Text("\(coordinator.processedTracks) / \(coordinator.totalTracks) tracks")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }

            if coordinator.phase == .indexing {
                Text("\(coordinator.indexedCount.formatted()) files indexed")
                    .font(.system(size: 12).monospacedDigit())
            }

            if let err = coordinator.lastError {
                Label(err, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.caption)
            }

            HStack(spacing: 8) {
                if coordinator.phase == .confirming || coordinator.phase == .indexing || coordinator.phase == .narrowing {
                    Button("Pause") { coordinator.pause() }.controlSize(.small)
                }
                if coordinator.phase == .paused {
                    Button("Resume") { coordinator.resume() }.buttonStyle(.borderedProminent).controlSize(.small)
                }
                Button("Cancel") { coordinator.cancel() }.controlSize(.small).foregroundStyle(.red)
                if coordinator.phase == .completed || coordinator.phase == .cancelled {
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
        case .completed:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .cancelled:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        case .paused:
            Image(systemName: "pause.circle.fill").foregroundStyle(.orange)
        default:
            ProgressView().controlSize(.small)
        }
    }

    private var phaseLabel: String {
        switch coordinator.phase {
        case .idle:       return "Idle"
        case .indexing:   return "Indexing local library…"
        case .narrowing:  return "Narrowing candidates…"
        case .confirming: return "Confirming via AcoustID…"
        case .paused:     return "Paused"
        case .completed:  return "Match complete"
        case .cancelled:  return "Cancelled"
        }
    }

    private func countBadge(label: String, count: Int, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(count.formatted())
                .font(.system(size: 16, weight: .bold).monospacedDigit())
                .foregroundStyle(count > 0 ? color : Color.secondary.opacity(0.5))
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}
