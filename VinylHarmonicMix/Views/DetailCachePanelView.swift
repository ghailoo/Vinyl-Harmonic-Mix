import SwiftUI

@MainActor
struct DetailCachePanelView: View {
    let coordinator: DetailCacheCoordinator

    @State private var isExpanded: Bool = true

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
        .animation(.easeInOut(duration: 0.2), value: isExpanded)
    }

    // MARK: - Expanded

    private var expandedContent: some View {
        VStack(spacing: 0) {
            progressBar
            header
            Divider()
            actionButtons
        }
    }

    private var progressBar: some View {
        ProgressView(
            value: Double(coordinator.passProcessed),
            total: Double(max(coordinator.passTotal, 1))
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
                if let item = coordinator.currentItem {
                    Text("\(item.title) — \(item.artist)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                HStack(spacing: 6) {
                    if let remaining = remainingLabel {
                        Text(remaining)
                        Text("·").foregroundStyle(.tertiary)
                    }
                    Text("\(coordinator.passProcessed) / \(coordinator.passTotal)")
                        .monospacedDigit()
                    if coordinator.newlyCachedCount > 0 {
                        Text("·").foregroundStyle(.tertiary)
                        Text("\(coordinator.newlyCachedCount) fetched")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                isExpanded.toggle()
            } label: {
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(isExpanded ? "Collapse panel" : "Expand panel")
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
                    if let item = coordinator.currentItem {
                        Text("·").foregroundStyle(.tertiary)
                        Text("\(item.title) — \(item.artist)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                Spacer()
                if let remaining = collapsedRemainingLabel {
                    Text(remaining)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
                Text("\(coordinator.passProcessed) / \(coordinator.passTotal)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize()
                Button {
                    isExpanded = true
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Expand panel")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
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
        switch coordinator.phase {
        case .scanning:
            return coordinator.isRefreshMode ? "Refreshing release details" : "Caching release details"
        case .paused:
            return "Cache paused"
        case .completed:
            let totalCached = coordinator.totalCollectionCount - coordinator.initialQueueCount + coordinator.newlyCachedCount
            return "Cache complete — \(coordinator.newlyCachedCount.formatted()) newly fetched · \(totalCached.formatted()) of \(coordinator.totalCollectionCount.formatted()) total"
        case .cancelled:
            return "Cache cancelled — \(coordinator.passProcessed) of \(coordinator.passTotal) processed"
        case .failed(let msg):
            return "Cache failed — \(msg)"
        case .idle:
            return ""
        }
    }

    private var remainingLabel: String? {
        guard case .scanning = coordinator.phase,
              coordinator.passProcessed > 0,
              coordinator.passTotal > coordinator.passProcessed else { return nil }
        let mins = coordinator.estimatedRemainingMinutes
        if mins < 2 { return "<1 min" }
        return "~\(mins) min"
    }

    private var collapsedPhaseLabel: String {
        switch coordinator.phase {
        case .scanning:  return "Caching"
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
}
