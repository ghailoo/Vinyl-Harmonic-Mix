import SwiftUI

@MainActor
struct RecordingsScanResultsView: View {
    let coordinator: RecordingsScanCoordinator
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
        .animation(.easeInOut(duration: 0.2), value: isExpanded)
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
        .animation(.easeInOut(duration: 0.2), value: toastMessage)
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
            .frame(height: panelContentHeight)
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
                statsRow(icon: "music.note.list",       iconColor: .green,    label: "Fetched",            count: coordinator.fetchedCount)
                statsRow(icon: "circle.dotted",         iconColor: .secondary, label: "Skipped (no MBID)", count: coordinator.skippedCount)
                statsRow(icon: "xmark.circle.fill",     iconColor: .red,      label: "Failed",             count: coordinator.failedCount)
                if isCompletedPhase && coordinator.fetchedCount > 0 {
                    Divider().padding(.vertical, 4)
                    statsRow(icon: "waveform",           iconColor: .accentColor, label: "Total tracks stored", count: coordinator.totalTrackCount)
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
            paneTitle("Failed")
            if coordinator.failedRecordings.isEmpty {
                Spacer()
                Text("None")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(coordinator.failedRecordings) { item in
                            FailedRecordingRowView(
                                item: item,
                                onOpenDetail: { onOpenItem(item.instanceId) },
                                onResetToUnscanned: {
                                    coordinator.resetToUnscanned(instanceId: item.instanceId)
                                    showToast("Reset — will retry on next scan")
                                }
                            )
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

    private var panelContentHeight: CGFloat {
        let base: CGFloat = 160
        let failedCount = coordinator.failedRecordings.count
        guard failedCount > 3 else { return base }
        return min(base + CGFloat(failedCount - 3) * 48, 320)
    }

    private var headerTitle: String {
        switch coordinator.phase {
        case .scanning:  return "Fetching track recording MBIDs"
        case .paused:    return "Track fetch paused"
        case .completed:
            return "Track fetch complete — \(coordinator.totalTrackCount.formatted()) tracks from \(coordinator.fetchedCount.formatted()) releases"
        case .cancelled:
            return "Track fetch cancelled — \(coordinator.passProcessed) of \(coordinator.passTotal) processed"
        case .failed(let msg): return "Track fetch failed — \(msg)"
        case .idle:      return ""
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
        case .scanning:  return "Fetching tracks"
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

// MARK: - Failed row with popover

private struct FailedRecordingRowView: View {
    let item: RecordingsScanCoordinator.FailedRecordingInfo
    let onOpenDetail: () -> Void
    let onResetToUnscanned: () -> Void

    @State private var showPopover = false

    var body: some View {
        Button { showPopover = true } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Text(item.artist)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showPopover, arrowEdge: .leading) {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(2)
                    Text(item.artist)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                Divider()
                VStack(alignment: .leading, spacing: 0) {
                    popoverButton("Open in detail view", systemImage: "doc.text.magnifyingglass") {
                        showPopover = false
                        onOpenDetail()
                    }
                    popoverButton("Reset — retry on next scan", systemImage: "arrow.counterclockwise") {
                        showPopover = false
                        onResetToUnscanned()
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(width: 260)
        }
    }

    private func popoverButton(_ label: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(label, systemImage: systemImage)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
    }
}
