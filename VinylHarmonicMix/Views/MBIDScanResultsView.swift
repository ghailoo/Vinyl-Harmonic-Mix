import SwiftUI

@MainActor
struct MBIDScanResultsView: View {
    let coordinator: MBIDScanCoordinator
    let onFilterSelect: (CollectionFilter) -> Void

    @State private var isExpanded: Bool = true

    var body: some View {
        VStack(spacing: 0) {
            if isExpanded {
                expandedContent
            } else {
                collapsedContent
            }
        }
        .frame(maxWidth: 720)
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

    // MARK: - Expanded branch

    private var expandedContent: some View {
        VStack(spacing: 0) {
            progressBar
            header
            Divider()
            HStack(spacing: 0) {
                matchResultsPane
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

    // MARK: - Collapsed branch

    private var collapsedContent: some View {
        VStack(spacing: 0) {
            progressBar

            HStack(spacing: 12) {
                HStack(spacing: 6) {
                    Text(collapsedPhaseLabel)
                        .font(.caption.weight(.medium))
                    if let item = coordinator.currentItem {
                        Text("·")
                            .foregroundStyle(.tertiary)
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

    private var collapsedPhaseLabel: String {
        switch coordinator.phase {
        case .scanning:
            return coordinator.currentPass == .indexedSearch ? "Scanning (search)" : "Scanning"
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

    // MARK: - Match results pane

    private var matchResultsPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            paneTitle("Match Results")
            VStack(spacing: 4) {
                matchRow(icon: "checkmark.circle.fill", iconColor: .green,
                         label: "Via URL relationship", count: coordinator.matchedCount,
                         filter: .matched)
                matchRow(icon: "checkmark.circle.fill", iconColor: .green,
                         label: "Via indexed search",   count: coordinator.searchMatchedCount,
                         filter: .matched)
                matchRow(icon: "circle",                iconColor: .secondary,
                         label: "Not found",            count: coordinator.notFoundCount,
                         filter: .notFound)
                matchRow(icon: "xmark.circle.fill",     iconColor: .red,
                         label: "Failed",               count: coordinator.failedCount,
                         filter: .failed)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func matchRow(icon: String, iconColor: Color, label: String,
                          count: Int, filter: CollectionFilter) -> some View {
        let tappable = count > 0
        return Button {
            if tappable { onFilterSelect(filter) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(tappable ? iconColor : Color.secondary.opacity(0.3))
                    .font(.system(size: 13))
                    .frame(width: 16)
                Text(label)
                    .font(.system(size: 13))
                    .foregroundStyle(tappable ? .primary : .secondary)
                Spacer()
                Text("\(count)")
                    .font(.system(size: 13).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tappable ? "Filter grid to show \(label.lowercased())" : "")
    }

    // MARK: - Failed pane

    private var failedPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            paneTitle("Failed")
            if coordinator.failedItems.isEmpty {
                Spacer()
                Text("None")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(coordinator.failedItems, id: \.title) { item in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title)
                                    .font(.system(size: 13, weight: .medium))
                                    .lineLimit(1)
                                Text(item.artist)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                Text(item.error)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                }
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
        switch coordinator.phase {
        case .scanning:
            return coordinator.currentPass == .urlRelationship
                ? "Scanning MusicBrainz IDs"
                : "Scanning MusicBrainz IDs (search pass)"
        case .paused:   return "Scan paused"
        case .completed:
            let matched = coordinator.matchedCount + coordinator.searchMatchedCount
            return "Scan complete — \(matched) of \(coordinator.totalCount) matched"
        case .cancelled:
            return "Scan cancelled — \(coordinator.scanned) of \(coordinator.total) processed"
        case .failed(let msg):
            return "Scan failed — \(msg)"
        case .idle:     return ""
        }
    }

    private var remainingLabel: String? {
        guard case .scanning = coordinator.phase,
              coordinator.passProcessed > 0,
              coordinator.passTotal > coordinator.passProcessed else { return nil }
        let remaining = coordinator.passTotal - coordinator.passProcessed
        let seconds = Double(remaining) * 1.05
        if seconds < 60 { return "<1 min" }
        return "~\(Int(ceil(seconds / 60))) min"
    }

    private func paneTitle(_ text: String) -> some View {
        Text(text)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 8)
    }
}
