import SwiftUI
import AppKit
import UniformTypeIdentifiers
import SwiftData

struct UnifiedTopBar: View {
    @Environment(SyncOrchestrator.self) private var syncOrchestrator
    @Environment(MBIDScanCoordinator.self) private var scanCoordinator
    @Environment(FileMatchCoordinator.self) private var fileMatchCoordinator
    @Environment(CueDetectionCoordinator.self) private var cueCoordinator
    @Environment(LocalAnalysisCoordinator.self) private var localAnalysisCoordinator
    @Environment(DriveMonitor.self) private var driveMonitor
    @Environment(\.modelContext) private var modelContext

    @State private var showExportSuccessAlert = false
    @State private var lastExportSummary: String = ""
    @State private var showBackupAlert = false
    @State private var lastBackupSummary: String = ""
    @State private var showRestoreAlert = false
    @State private var lastRestoreSummary: String = ""

    var body: some View {
        HStack(spacing: 16) {
            libraryBubbleRow
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(1)

            NowPlayingBar()
                .frame(maxWidth: .infinity)

            // Force @Observable tracking for all coordinator state we read in
            // activeOperations and activeLibraryBubbleTitles
            let _ = driveMonitor.isAvailable
            let _ = syncOrchestrator.isSyncing
            let _ = syncOrchestrator.syncStatus
            let _ = scanCoordinator.scanned
            let _ = scanCoordinator.phase
            let _ = fileMatchCoordinator.phase
            let _ = fileMatchCoordinator.waveformsPausing
            let _ = cueCoordinator.phase
            let _ = localAnalysisCoordinator.phase

            HStack(spacing: 8) {
                ForEach(activeOperations, id: \.name) { status in
                    OperationStatusBubble(status: status)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) {
            LinearGradient(
                colors: [Color.primary.opacity(0.08), Color.primary.opacity(0)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 8)
        }
        .alert("Rekordbox Export", isPresented: $showExportSuccessAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(lastExportSummary)
        }
        .alert("Matches Backup", isPresented: $showBackupAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(lastBackupSummary)
        }
        .alert("Matches Restore", isPresented: $showRestoreAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(lastRestoreSummary)
        }
    }

    private func triggerExport() {
        guard let result = fileMatchCoordinator.generateRekordboxXML() else { return }

        let panel = NSSavePanel()
        panel.title = "Export Rekordbox XML Library"
        panel.nameFieldStringValue = "VinylHarmonicMix-Library.xml"
        panel.allowedContentTypes = [.xml]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try result.xml.write(to: url, atomically: true, encoding: .utf8)
                lastExportSummary = "Exported \(result.trackCount) tracks and \(result.setCount) sets to \(url.lastPathComponent)."
            } catch {
                print("[REKORDBOX-EXPORT] Write failed: \(error)")
                lastExportSummary = "Export failed: \(error.localizedDescription)"
            }
            showExportSuccessAlert = true
        }
    }

    private func runBackupExport() {
        let panel = NSSavePanel()
        panel.title = "Backup Matches"
        panel.nameFieldStringValue = "VinylHarmonicMix-Matches-Backup.json"
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                do {
                    let backup = try MatchesBackupService.collectBackup(modelContext: modelContext)
                    try MatchesBackupService.writeBackup(backup, to: url)

                    // Persist security-scoped bookmark for Phase 2 (launch detection) and Phase 3 (auto-update).
                    if let bookmark = try? url.bookmarkData(
                        options: .withSecurityScope,
                        includingResourceValuesForKeys: nil,
                        relativeTo: nil
                    ) {
                        UserDefaults.standard.set(bookmark, forKey: UserDefaults.matchesBackupBookmarkKey)
                    }

                    lastBackupSummary = "Saved \(backup.totalEntries) confident matches to \(url.lastPathComponent)."
                } catch {
                    lastBackupSummary = "Backup failed: \(error.localizedDescription)"
                }
                showBackupAlert = true
            }
        }
    }

    private func runBackupImport() {
        let panel = NSOpenPanel()
        panel.title = "Restore Matches from Backup"
        panel.allowedContentTypes = [.json]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                do {
                    let backup = try MatchesBackupService.readBackup(from: url)
                    let result = try MatchesBackupService.applyBackup(backup, modelContext: modelContext)

                    if let bookmark = try? url.bookmarkData(
                        options: .withSecurityScope,
                        includingResourceValuesForKeys: nil,
                        relativeTo: nil
                    ) {
                        UserDefaults.standard.set(bookmark, forKey: UserDefaults.matchesBackupBookmarkKey)
                    }

                    lastRestoreSummary = """
                    Restored \(result.restored) matches from \(url.lastPathComponent).
                    Skipped \(result.skippedAlreadyMatched) (already matched).
                    Skipped \(result.skippedFileMissing) (file not found in library).
                    Skipped \(result.skippedTrackMissing) (track not found in library).
                    Total in backup: \(result.totalInBackup).
                    """
                } catch {
                    lastRestoreSummary = "Restore failed: \(error.localizedDescription)"
                }
                showRestoreAlert = true
            }
        }
    }

    private var activeOperations: [OperationStatus] {
        var result: [OperationStatus] = []

        if syncOrchestrator.isSyncing {
            result.append(.simple(
                name: "Update All",
                icon: "arrow.triangle.2.circlepath",
                isRunning: true,
                statusText: syncOrchestrator.syncStatus.isEmpty ? nil : syncOrchestrator.syncStatus
            ))
        }

        if case .scanning = scanCoordinator.phase {
            result.append(.simple(
                name: "Find IDs",
                icon: "magnifyingglass",
                isRunning: true,
                count: scanCoordinator.scanned,
                total: scanCoordinator.total
            ))
        }

        if let fileMatch = fileMatchStatus() {
            result.append(fileMatch)
        }

        if localAnalysisCoordinator.phase == .analyzing || localAnalysisCoordinator.phase == .paused {
            result.append(.simple(
                name: "Detect BPM/Key",
                icon: "waveform.badge.magnifyingglass",
                isRunning: true,
                count: localAnalysisCoordinator.analyzedCount,
                total: localAnalysisCoordinator.totalCount,
                statusText: skippedText(localAnalysisCoordinator.analyzedCount, localAnalysisCoordinator.totalCount,
                                        skipped: localAnalysisCoordinator.skippedFolderCount)
            ))
        }

        if cueCoordinator.phase == .detecting {
            result.append(.simple(
                name: "Find Cues",
                icon: "scope",
                isRunning: true,
                count: cueCoordinator.processedCount,
                total: cueCoordinator.totalCount,
                statusText: skippedText(cueCoordinator.processedCount, cueCoordinator.totalCount,
                                        skipped: cueCoordinator.skippedFolderCount)
            ))
        }

        return result
    }

    /// "count / total · N folders skipped" when folders were skipped; nil keeps the default label.
    private func skippedText(_ count: Int, _ total: Int, skipped: Int) -> String? {
        skipped > 0 ? "\(count) / \(total) · \(Self.foldersSkipped(skipped))" : nil
    }

    private static func foldersSkipped(_ n: Int) -> String {
        "\(n) folder\(n == 1 ? "" : "s") skipped"
    }

    private func fileMatchStatus() -> OperationStatus? {
        let c = fileMatchCoordinator
        switch c.phase {
        case .indexing:
            return .simple(name: "Link Files", icon: "link", isRunning: true,
                           count: c.indexingStepCount, total: c.indexingStepTotal,
                           statusText: (c.indexingStep.isEmpty
                               ? "Indexing \(c.indexedCount.formatted())"
                               : c.indexingStep)
                               + (c.skippedFolderCount > 0 ? " · \(Self.foldersSkipped(c.skippedFolderCount))" : ""))
        case .matching:
            return .simple(name: "Link Files", icon: "link", isRunning: true,
                           count: c.processedTracks, total: c.totalTracks,
                           statusText: skippedText(c.processedTracks, c.totalTracks, skipped: c.skippedFolderCount))
        case .generatingWaveforms, .generatingWaveformsPaused:
            return OperationStatus(
                name: "Waveforms",
                icon: "waveform",
                isRunning: true,
                count: c.waveformsGenerated,
                total: c.waveformsTotal,
                statusText: nil,
                pauseAction: { c.pauseWaveformGeneration() },
                resumeAction: { c.resumeWaveformGeneration() },
                isPaused: c.phase == .generatingWaveformsPaused,
                isPausing: c.waveformsPausing
            )
        default:
            return nil
        }
    }

    private func bubbleColor(for title: String) -> Color {
        switch title {
        case "Update All":     return .blue
        case "Find IDs":       return .purple
        case "Link Files":     return .orange
        case "Detect BPM/Key": return .mint
        case "Find Cues":      return .pink
        case "Rekordbox":      return .cyan
        case "Back Up":        return .brown
        case "Restore":        return .indigo
        default:               return .accentColor
        }
    }

    /// Progressively smaller bubble rows so a growing button count degrades by
    /// keeping as many labels as fit and tucking the rest into a trailing "More"
    /// menu (icon + full label, never silently unlabeled); only once that no longer
    /// fits do all labels drop at once, and only as an absolute last resort do we
    /// fall back to scrolling — never by clipping text mid-word or letter-wrapping it.
    @ViewBuilder
    private var libraryBubbleRow: some View {
        let actions = libraryActions
        ViewThatFits(in: .horizontal) {
            libraryButtons(showsLabels: true)
            overflowLibraryRow(actions: actions, labeledCount: 5)
            overflowLibraryRow(actions: actions, labeledCount: 2)
            libraryButtons(showsLabels: false)
            ScrollView(.horizontal, showsIndicators: false) {
                libraryButtons(showsLabels: false)
            }
        }
    }

    /// One library toolbar action — shared by the labeled row and the overflow
    /// "More" menu so their icon/label/tooltip/action can't drift apart.
    private struct LibraryAction {
        let title: String
        let tooltip: String
        let icon: String
        let disabled: Bool
        let action: () -> Void
    }

    private var libraryActions: [LibraryAction] {
        [
            LibraryAction(title: "Update All", tooltip: "Import new Discogs releases run step them",
                          icon: "arrow.triangle.2.circlepath", disabled: false, action: { syncOrchestrator.startSync() }),
            LibraryAction(title: "Find IDs", tooltip: "Look up MusicBrainz IDs all releases",
                          icon: "magnifyingglass.circle", disabled: false, action: { scanCoordinator.start() }),
            LibraryAction(title: "Link Files", tooltip: "Link tracks audio files on NAS",
                          icon: "link.circle", disabled: !driveMonitor.isAvailable, action: { fileMatchCoordinator.startFullScan() }),
            LibraryAction(title: "Detect BPM/Key", tooltip: "Analyze own files BPM key (needs NAS)",
                          icon: "waveform.badge.magnifyingglass", disabled: !driveMonitor.isAvailable, action: { localAnalysisCoordinator.startFileAnalysis() }),
            LibraryAction(title: "Find Cues", tooltip: "Detect cue points in linked files",
                          icon: "scope", disabled: !driveMonitor.isAvailable, action: { cueCoordinator.startDetection(scope: .matched) }),
            LibraryAction(title: "Rekordbox", tooltip: "Export library sets Rekordbox XML",
                          icon: "music.note.list", disabled: false, action: { triggerExport() }),
            LibraryAction(title: "Back Up", tooltip: "Save file links JSON file",
                          icon: "externaldrive.badge.timemachine", disabled: false, action: { runBackupExport() }),
            LibraryAction(title: "Restore", tooltip: "Load file links backup",
                          icon: "arrow.clockwise.icloud", disabled: false, action: { runBackupImport() }),
        ]
    }

    /// `labeledCount` actions (in order) stay inline with their label; the rest are
    /// tucked into a trailing "More" menu listing icon + full label, so a narrow
    /// window loses button labels gradually instead of all at once.
    @ViewBuilder
    private func overflowLibraryRow(actions: [LibraryAction], labeledCount: Int) -> some View {
        let visible = Array(actions.prefix(labeledCount))
        let overflow = Array(actions.suffix(from: min(labeledCount, actions.count)))
        HStack(spacing: 8) {
            Color.clear.frame(width: 32, height: 1)
            ForEach(visible, id: \.title) { action in
                libraryBubble(title: action.title, tooltip: action.tooltip, icon: action.icon,
                              disabled: action.disabled, showsLabel: true, action: action.action)
            }
            if !overflow.isEmpty {
                Menu {
                    ForEach(overflow, id: \.title) { action in
                        Button(action: action.action) {
                            Label(action.title, systemImage: action.icon)
                        }
                        .disabled(action.disabled)
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.body.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 22)
                .help("More library actions")
                .accessibilityLabel("More library actions")
            }
        }
    }

    @ViewBuilder
    private func libraryButtons(showsLabels: Bool) -> some View {
        HStack(spacing: 8) {
            // Clears the sidebar toggle button, which overlaps this row's own
            // leading padding and otherwise clips the "Update All" bubble.
            Color.clear.frame(width: 32, height: 1)
            libraryBubble(title: "Update All", tooltip: "Import new Discogs releases run step them",
                          icon: "arrow.triangle.2.circlepath", showsLabel: showsLabels) { syncOrchestrator.startSync() }
            libraryBubble(title: "Find IDs", tooltip: "Look up MusicBrainz IDs all releases",
                          icon: "magnifyingglass.circle", showsLabel: showsLabels) { scanCoordinator.start() }
            libraryBubble(title: "Link Files", tooltip: "Link tracks audio files on NAS",
                          icon: "link.circle",
                          disabled: !driveMonitor.isAvailable, showsLabel: showsLabels) { fileMatchCoordinator.startFullScan() }
            libraryBubble(title: "Detect BPM/Key", tooltip: "Analyze own files BPM key (needs NAS)",
                          icon: "waveform.badge.magnifyingglass",
                          disabled: !driveMonitor.isAvailable, showsLabel: showsLabels) { localAnalysisCoordinator.startFileAnalysis() }
            libraryBubble(title: "Find Cues", tooltip: "Detect cue points in linked files",
                          icon: "scope",
                          disabled: !driveMonitor.isAvailable, showsLabel: showsLabels) { cueCoordinator.startDetection(scope: .matched) }

            Divider().frame(height: 20)

            libraryBubble(title: "Rekordbox", tooltip: "Export library sets Rekordbox XML",
                          icon: "music.note.list", showsLabel: showsLabels) { triggerExport() }
            libraryBubble(title: "Back Up", tooltip: "Save file links JSON file",
                          icon: "externaldrive.badge.timemachine", showsLabel: showsLabels) { runBackupExport() }
            libraryBubble(title: "Restore", tooltip: "Load file links backup",
                          icon: "arrow.clockwise.icloud", showsLabel: showsLabels) { runBackupImport() }
        }
    }

    /// Titles of the library bubbles whose coordinator currently has a running
    /// operation, so that bubble can be tinted to point at the matching status
    /// bubble on the right (the only link between the two today is this highlight).
    private var activeLibraryBubbleTitles: Set<String> {
        var active: Set<String> = []
        if syncOrchestrator.isSyncing { active.insert("Update All") }
        if case .scanning = scanCoordinator.phase { active.insert("Find IDs") }
        switch fileMatchCoordinator.phase {
        case .indexing, .matching, .generatingWaveforms, .generatingWaveformsPaused:
            active.insert("Link Files")
        default:
            break
        }
        if localAnalysisCoordinator.phase == .analyzing || localAnalysisCoordinator.phase == .paused {
            active.insert("Detect BPM/Key")
        }
        if cueCoordinator.phase == .detecting { active.insert("Find Cues") }
        return active
    }

    @ViewBuilder
    private func libraryBubble(title: String, tooltip: String, icon: String, disabled: Bool = false, showsLabel: Bool = true, action: @escaping () -> Void) -> some View {
        let tint = bubbleColor(for: title)
        let isActive = activeLibraryBubbleTitles.contains(title)
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.body.weight(.medium))
                    .foregroundStyle(disabled ? Color.secondary : tint)
                if showsLabel {
                    Text(title)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(disabled ? Color.secondary : Color.primary)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .buttonStyle(LibraryBubbleButtonStyle(tint: tint, isActive: isActive))
        .disabled(disabled)
        .opacity(disabled ? 0.5 : 1.0)
        .help(disabled ? "\(title) (unavailable — no library folder reachable)" : tooltip)
        .accessibilityLabel(disabled ? "\(title) (unavailable — no library folder reachable)" : tooltip)
    }
}

struct LibraryBubbleButtonStyle: ButtonStyle {
    let tint: Color
    /// True while this bubble's operation is running, so it visibly links to its
    /// status bubble on the right without any other connection between the two.
    var isActive: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                ZStack {
                    Capsule().fill(.regularMaterial)
                    Capsule()
                        .fill(tint.opacity(isActive ? 0.22 : (isHovering ? 0.18 : 0)))
                        .animation(.snappy, value: isHovering)
                        .animation(.snappy, value: isActive)
                    Capsule()
                        .stroke(
                            isActive ? tint.opacity(0.7) : (isHovering ? tint.opacity(0.4) : Color.primary.opacity(0.08)),
                            lineWidth: isActive ? 1.2 : 0.5
                        )
                        .animation(.snappy, value: isHovering)
                        .animation(.snappy, value: isActive)
                }
            )
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1.0)
            .animation(.snappy, value: configuration.isPressed)
            .onHover { hovering in
                isHovering = hovering
            }
    }
}

/// Shared press/hover feedback for tappable surfaces that already draw their own
/// background/shape (grid cards, harmonic-strip tiles, suggestion bubbles) — unlike
/// `LibraryBubbleButtonStyle`, this doesn't impose a capsule, just a hover brighten
/// and a press scale-down so it works on any shape.
struct InteractiveTileButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .brightness(isHovering ? 0.06 : 0)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1.0)
            .animation(.snappy, value: isHovering)
            .animation(.snappy, value: configuration.isPressed)
            .onHover { hovering in
                isHovering = hovering
            }
    }
}
