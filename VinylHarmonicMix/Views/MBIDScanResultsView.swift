import SwiftUI

@MainActor
struct MBIDScanResultsView: View {
    let coordinator: MBIDScanCoordinator
    let onFilterSelect: (CollectionFilter) -> Void
    let onOpenItem: (Int) -> Void

    @Environment(RecordingsScanCoordinator.self) private var recordingsCoordinator
    @Environment(AudioFeaturesScanCoordinator.self) private var audioFeaturesCoordinator

    @State private var isExpanded: Bool = true
    @State private var mbidEntryItem: MBIDScanCoordinator.FailedItemInfo? = nil
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
        .sheet(item: $mbidEntryItem) { item in
            MBIDManualEntryView(
                item: item,
                onSubmit: { mbid in
                    coordinator.setMBIDManually(instanceId: item.instanceId, mbid: mbid)
                    mbidEntryItem = nil
                    showToast("MBID set for \(item.title)")
                },
                onCancel: {
                    mbidEntryItem = nil
                }
            )
        }
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
                needsReviewPane
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
            Button {
                isExpanded.toggle()
            } label: {
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
                .accessibilityLabel("Expand panel")
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
                         label: "Via link",             count: coordinator.matchedCount,
                         filter: .matched)
                matchRow(icon: "checkmark.circle.fill", iconColor: .green,
                         label: "Via barcode",          count: coordinator.viaBarcodeCount,
                         filter: .matched)
                matchRow(icon: "checkmark.circle.fill", iconColor: .green,
                         label: "Via catno",            count: coordinator.viaCatalogNumberCount,
                         filter: .matched)
                matchRow(icon: "checkmark.circle.fill", iconColor: .green,
                         label: "Via search",           count: coordinator.viaFuzzySearchCount,
                         filter: .matched)
                if coordinator.manualMatchCount > 0 {
                    matchRow(icon: "pencil.circle.fill", iconColor: .green,
                             label: "Manually matched",  count: coordinator.manualMatchCount,
                             filter: .matched)
                }
                matchRow(icon: "exclamationmark.circle", iconColor: .orange,
                         label: "Needs review",         count: coordinator.needsReviewCount,
                         filter: .needsReview)
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
                    .font(.body)
                    .frame(width: 16)
                Text(label)
                    .font(.body)
                    .foregroundStyle(tappable ? .primary : .secondary)
                Spacer()
                Text("\(count)")
                    .font(.body.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tappable ? "Filter grid to show \(label.lowercased())" : "")
        .accessibilityLabel(tappable ? "Filter grid to show \(label.lowercased())" : "")
    }

    // MARK: - Needs review pane

    private var needsReviewPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            paneTitle("Needs Review")
            if coordinator.needsReviewItems.isEmpty {
                Spacer()
                Text("None")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(coordinator.needsReviewItems) { item in
                            NeedsReviewRowView(
                                item: item,
                                onAccept: { mbid in
                                    coordinator.setMBIDManuallyAndEnrich(
                                        instanceId: item.instanceId,
                                        mbid: mbid,
                                        recordingsCoordinator: recordingsCoordinator,
                                        audioFeaturesCoordinator: audioFeaturesCoordinator
                                    )
                                    showToast("MBID set for \(item.title)")
                                },
                                onNotOnMusicBrainz: {
                                    coordinator.resetToNotFound(instanceId: item.instanceId)
                                    showToast("Marked \"Not found\" for \(item.title)")
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
                        ForEach(coordinator.failedItems) { item in
                            FailedRowView(
                                item: item,
                                onOpenDetail: {
                                    onOpenItem(item.instanceId)
                                },
                                onResetToNotFound: {
                                    coordinator.resetToNotFound(instanceId: item.instanceId)
                                    showToast("Reset to \"Not found\" — run the MBID scan again to retry")
                                },
                                onSetMBIDManually: {
                                    mbidEntryItem = item
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

    // MARK: - Adaptive pane height

    private var panelContentHeight: CGFloat {
        let baseHeight: CGFloat = 180
        let rowHeight: CGFloat = 56
        let overflowRows = max(coordinator.failedItems.count, coordinator.needsReviewItems.count) - 3
        guard overflowRows > 0 else { return baseHeight }
        return min(baseHeight + CGFloat(overflowRows) * rowHeight, 360)
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
            let matched = coordinator.matchedCount + coordinator.searchMatchedCount + coordinator.manualMatchCount
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

    private func showToast(_ message: String) {
        toastMessage = message
        Task {
            try? await Task.sleep(for: .seconds(2))
            toastMessage = nil
        }
    }
}

// MARK: - Failed row with popover

private struct FailedRowView: View {
    let item: MBIDScanCoordinator.FailedItemInfo
    let onOpenDetail: () -> Void
    let onResetToNotFound: () -> Void
    let onSetMBIDManually: () -> Void

    @State private var showPopover = false

    var body: some View {
        Button { showPopover = true } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.body.weight(.medium))
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
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showPopover, arrowEdge: .leading) {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title)
                        .font(.body.weight(.semibold))
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
                    popoverButton("Reset to \"Not found\"", systemImage: "arrow.counterclockwise") {
                        showPopover = false
                        onResetToNotFound()
                    }
                    popoverButton("Set MBID manually…", systemImage: "pencil") {
                        showPopover = false
                        onSetMBIDManually()
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

// MARK: - Needs-review row with popover

private struct NeedsReviewRowView: View {
    let item: MBIDScanCoordinator.NeedsReviewItemInfo
    let onAccept: (String) -> Void
    let onNotOnMusicBrainz: () -> Void

    @State private var showPopover = false

    var body: some View {
        Button { showPopover = true } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text(item.artist)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text("\(item.candidates.count) candidate\(item.candidates.count == 1 ? "" : "s")")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showPopover, arrowEdge: .leading) {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title)
                        .font(.body.weight(.semibold))
                        .lineLimit(2)
                    Text(item.artist)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    ForEach(item.candidates) { candidate in
                        candidateRow(candidate)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

                Divider()

                Button(role: .destructive) {
                    showPopover = false
                    onNotOnMusicBrainz()
                } label: {
                    Label("Not on MusicBrainz", systemImage: "xmark.circle")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
            }
            .frame(width: 340)
        }
    }

    private func candidateRow(_ candidate: MBReviewCandidate) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(candidate.title)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Text(candidate.artist)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text([candidate.format, candidate.country, candidate.date, candidate.catno]
                    .filter { !$0.isEmpty }
                    .joined(separator: " · "))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text("\(Int(candidate.score * 100))%")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                Button("Accept") {
                    onAccept(candidate.mbid)
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }
        }
    }
}

// MARK: - MBID manual entry sheet

private struct MBIDManualEntryView: View {
    let item: MBIDScanCoordinator.FailedItemInfo
    let onSubmit: (String) -> Void
    let onCancel: () -> Void

    @State private var mbidText = ""
    @State private var validationError: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Set MBID manually")
                .font(.headline)

            Text("\(item.title) — \(item.artist)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                TextField("e.g. 550e8400-e29b-41d4-a716-446655440000", text: $mbidText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                if let error = validationError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            HStack {
                Button("Cancel", action: onCancel)
                    .buttonStyle(.bordered)
                Spacer()
                Button("Set MBID") {
                    let trimmed = mbidText.trimmingCharacters(in: .whitespaces)
                    if isValidMBID(trimmed) {
                        validationError = nil
                        onSubmit(trimmed)
                    } else {
                        validationError = "Not a valid MBID. Format: 8-4-4-4-12 hex characters."
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(mbidText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 420)
    }

    private func isValidMBID(_ s: String) -> Bool {
        let pattern = "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"
        return s.range(of: pattern, options: .regularExpression) != nil
    }
}
