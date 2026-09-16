import SwiftUI

@MainActor
struct AudioFeaturesScanResultsView: View {
    let coordinator: AudioFeaturesScanCoordinator
    let onOpenItem: (Int) -> Void

    @State private var isExpanded: Bool = true
    @State private var toastMessage: String? = nil

    var body: some View {
        VStack(spacing: 0) {
            if isExpanded {
                expandedContent
            } else {
                collapsedContent
            }
        }
        .frame(maxWidth: 1200)
        .fixedSize(horizontal: false, vertical: true)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.12), radius: 12, x: 0, y: 3)
        .animation(.snappy, value: isExpanded)
        .overlay(alignment: .bottom) {
            if let msg = toastMessage {
                Text(msg)
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.thinMaterial, in: Capsule())
                    .padding(.bottom, 12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: toastMessage)
    }

    // MARK: - Expanded

    private var expandedContent: some View {
        VStack(spacing: 0) {
            progressBar
            header
            Divider()
            HStack(spacing: 0) {
                statsPane
                Divider()
                failedPane
            }
            .frame(height: 160)
            Divider()
            actionButtons
        }
    }

    private var progressBar: some View {
        ProgressView(
            value: Double(coordinator.batchesProcessed),
            total: Double(max(coordinator.batchesTotal, 1))
        )
        .progressViewStyle(.linear)
        .tint(isCompletedPhase ? .green : .accentColor)
        .padding(.top, 8)
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(headerTitle)
                    .font(.headline)
                if let preview = coordinator.currentBatchPreview {
                    Text("Batch \(coordinator.batchesProcessed + 1) of \(coordinator.batchesTotal) · \(preview)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                HStack(spacing: 6) {
                    if let remaining = remainingLabel {
                        Text(remaining)
                        Text("·").foregroundStyle(.tertiary)
                    }
                    Text("\(coordinator.batchesProcessed) / \(coordinator.batchesTotal) batches")
                        .monospacedDigit()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button { isExpanded.toggle() } label: {
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(isExpanded ? "Collapse panel" : "Expand panel")
            .accessibilityLabel(isExpanded ? "Collapse panel" : "Expand panel")
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 10)
    }

    // MARK: - Collapsed

    private var collapsedContent: some View {
        VStack(spacing: 0) {
            progressBar
            HStack(spacing: 12) {
                HStack(spacing: 6) {
                    Text(collapsedPhaseLabel)
                        .font(.caption.weight(.medium))
                    if let preview = coordinator.currentBatchPreview {
                        Text("·").foregroundStyle(.tertiary)
                        Text(preview)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                if let remaining = collapsedRemainingLabel {
                    Text(remaining)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
                Text("\(coordinator.batchesProcessed) / \(coordinator.batchesTotal)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize()
                Button { isExpanded = true } label: {
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Expand panel")
                .accessibilityLabel("Expand panel")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    // MARK: - Stats pane

    private var statsPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            paneTitle("Results")
            VStack(spacing: 4) {
                statsRow(icon: "waveform",           iconColor: .green,     label: "Found (with data)",  count: coordinator.tracksFound)
                statsRow(icon: "circle.dotted",      iconColor: .secondary, label: "Not in dataset",     count: coordinator.tracksMissing)
                statsRow(icon: "xmark.circle.fill",  iconColor: .red,       label: "Tracks in failed batches", count: coordinator.tracksFailed)
                if isCompletedPhase && coordinator.tracksFound > 0 {
                    Divider().padding(.vertical, 4)
                    statsRow(icon: "checkmark.seal.fill", iconColor: .accentColor, label: "Total stored",
                             count: coordinator.tracksFound + coordinator.tracksMissing)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func statsRow(icon: String, iconColor: Color, label: String, count: Int) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(count > 0 ? iconColor : Color.secondary.opacity(0.3))
                .font(.system(size: 13))
                .frame(width: 16)
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(count > 0 ? .primary : .secondary)
            Spacer()
            Text("\(count)")
                .font(.system(size: 13).monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Failed pane

    private var failedPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            paneTitle("Failed batches")
            if coordinator.tracksFailed == 0 {
                Spacer()
                Text("None")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                Spacer()
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                            .font(.system(size: 13))
                        Text("\(coordinator.tracksFailed) tracks in batches that failed")
                            .font(.system(size: 13))
                    }
                    Text("These will be retried on the next scan.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    // MARK: - Action buttons

    @ViewBuilder
    private var actionButtons: some View {
        HStack(spacing: 8) {
            switch coordinator.phase {
            case .scanning:
                Button("Pause")  { coordinator.pause() }  .buttonStyle(.bordered).controlSize(.small)
                Button("Cancel") { coordinator.cancel() } .buttonStyle(.bordered).controlSize(.small)
            case .paused:
                Button("Resume") { coordinator.resume() } .buttonStyle(.borderedProminent).controlSize(.small)
                Button("Cancel") { coordinator.cancel() } .buttonStyle(.bordered).controlSize(.small)
            case .completed, .cancelled, .failed:
                Button("Dismiss") { coordinator.dismissPanel() } .buttonStyle(.bordered).controlSize(.small)
            default:
                EmptyView()
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Helpers

    private var isCompletedPhase: Bool {
        if case .completed = coordinator.phase { return true }
        return false
    }

    private var headerTitle: String {
        let isEnrich = coordinator.isEnrichPass
        switch coordinator.phase {
        case .scanning:
            return isEnrich
                ? "Filling in BPM + key (1.1s/batch)"
                : "Fetching audio features (2.2s/batch)"
        case .paused:
            return isEnrich ? "BPM + key fill paused" : "Audio features scan paused"
        case .completed:
            let total = coordinator.tracksFound + coordinator.tracksMissing
            return isEnrich
                ? "BPM + key complete — \(coordinator.tracksFound.formatted()) of \(total.formatted()) tracks filled"
                : "Audio features complete — \(coordinator.tracksFound.formatted()) of \(total.formatted()) tracks in dataset"
        case .cancelled:
            return (isEnrich ? "BPM + key fill cancelled" : "Audio features cancelled")
                + " — \(coordinator.batchesProcessed) of \(coordinator.batchesTotal) batches"
        case .failed(let msg):
            return "Audio features scan failed — \(msg)"
        case .idle:
            return ""
        }
    }

    private var remainingLabel: String? {
        guard case .scanning = coordinator.phase,
              coordinator.batchesProcessed > 0,
              coordinator.batchesTotal > coordinator.batchesProcessed else { return nil }
        let mins = coordinator.estimatedRemainingMinutes
        return mins < 2 ? "<1 min" : "~\(mins) min"
    }

    private var collapsedPhaseLabel: String {
        switch coordinator.phase {
        case .scanning:  return "Fetching audio features"
        case .paused:    return "Paused"
        case .completed: return "Complete"
        case .cancelled: return "Cancelled"
        case .failed:    return "Failed"
        case .idle:      return ""
        }
    }

    private var collapsedRemainingLabel: String? {
        guard case .scanning = coordinator.phase,
              coordinator.estimatedRemainingMinutes > 0 else { return nil }
        return coordinator.estimatedRemainingMinutes < 2
            ? "<1 min"
            : "~\(coordinator.estimatedRemainingMinutes) min"
    }

    private func paneTitle(_ text: String) -> some View {
        Text(text)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 8)
    }

    private func showToast(_ message: String) {
        toastMessage = message
        Task {
            try? await Task.sleep(for: .seconds(2))
            toastMessage = nil
        }
    }
}
