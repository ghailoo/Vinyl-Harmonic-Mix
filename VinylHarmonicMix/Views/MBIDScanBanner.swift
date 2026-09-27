import SwiftUI

struct MBIDScanBanner: View {
    @Environment(MBIDScanCoordinator.self) private var coordinator

    var body: some View {
        HStack(spacing: 12) {
            icon
            statusText
            Spacer()
            progressIndicator
            actionButtons
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    @ViewBuilder
    private var icon: some View {
        switch coordinator.phase {
        case .scanning:
            ProgressView()
                .controlSize(.small)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        case .cancelled:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.secondary)
        default:
            Image(systemName: "pause.circle.fill")
                .foregroundStyle(.secondary)
        }
    }

    private var statusText: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(titleText)
                .font(.body.weight(.medium))
            Text(subtitleText)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var titleText: String {
        let isSearch = coordinator.scanMode == .searchFallback
        switch coordinator.phase {
        case .scanning:  return isSearch ? "Scanning MusicBrainz IDs (search)" : "Scanning MusicBrainz IDs"
        case .paused:    return isSearch ? "Search scan paused" : "Scan paused"
        case .completed: return "Scan complete"
        case .cancelled: return "Scan cancelled"
        case .failed(let msg): return "Scan failed: \(msg)"
        case .idle:      return "Ready to scan"
        }
    }

    private var subtitleText: String {
        let total = coordinator.total
        let scanned = coordinator.scanned
        if total > 0 {
            return "\(min(scanned, total)) of \(total) releases"
        }
        return ""
    }

    @ViewBuilder
    private var progressIndicator: some View {
        if coordinator.total > 0 {
            switch coordinator.phase {
            case .scanning, .paused:
                ProgressView(value: Double(min(coordinator.scanned, coordinator.total)), total: Double(max(coordinator.total, 1)))
                    .progressViewStyle(.linear)
                    .frame(width: 140)
            default:
                EmptyView()
            }
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        switch coordinator.phase {
        case .scanning:
            Button("Pause") { coordinator.pause() }
                .buttonStyle(.bordered)
                .controlSize(.small)
            Button("Cancel") { coordinator.cancel() }
                .buttonStyle(.bordered)
                .controlSize(.small)
        case .paused:
            Button("Resume") { coordinator.resume() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            Button("Cancel") { coordinator.cancel() }
                .buttonStyle(.bordered)
                .controlSize(.small)
        case .completed, .cancelled, .failed:
            Button("Dismiss") { coordinator.dismissPanel() }
                .buttonStyle(.bordered)
                .controlSize(.small)
        case .idle:
            EmptyView()
        }
    }
}
