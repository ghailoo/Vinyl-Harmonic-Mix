import SwiftUI
import AppKit
import UniformTypeIdentifiers
import SwiftData

struct UnifiedTopBar: View {
    @Environment(SyncOrchestrator.self) private var syncOrchestrator
    @Environment(MBIDScanCoordinator.self) private var scanCoordinator
    @Environment(AudioFeaturesScanCoordinator.self) private var audioFeaturesCoordinator
    @Environment(FileMatchCoordinator.self) private var fileMatchCoordinator
    @Environment(CueDetectionCoordinator.self) private var cueCoordinator
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
            let _ = audioFeaturesCoordinator.batchesProcessed
            let _ = audioFeaturesCoordinator.phase
            let _ = fileMatchCoordinator.phase
            let _ = fileMatchCoordinator.waveformsPausing
            let _ = cueCoordinator.phase

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
                name: "Sync",
                icon: "arrow.triangle.2.circlepath",
                isRunning: true,
                statusText: syncOrchestrator.syncStatus.isEmpty ? nil : syncOrchestrator.syncStatus
            ))
        }

        if case .scanning = scanCoordinator.phase {
            result.append(.simple(
                name: "MBID Scan",
                icon: "magnifyingglass",
                isRunning: true,
                count: scanCoordinator.scanned,
                total: scanCoordinator.total
            ))
        }

        if case .scanning = audioFeaturesCoordinator.phase {
            result.append(.simple(
                name: "AcousticBrainz",
                icon: "waveform.circle",
                isRunning: true,
                count: audioFeaturesCoordinator.batchesProcessed,
                total: audioFeaturesCoordinator.batchesTotal
            ))
        }

        if let fileMatch = fileMatchStatus() {
            result.append(fileMatch)
        }

        if cueCoordinator.phase == .detecting {
            result.append(.simple(
                name: "Cue Detection",
                icon: "scope",
                isRunning: true,
                count: cueCoordinator.processedCount,
                total: cueCoordinator.totalCount
            ))
        }

        return result
    }

    private func fileMatchStatus() -> OperationStatus? {
        let c = fileMatchCoordinator
        switch c.phase {
        case .indexing:
            return .simple(name: "Match Audio", icon: "link", isRunning: true,
                           count: c.indexingStepCount, total: c.indexingStepTotal,
                           statusText: c.indexingStep.isEmpty
                               ? "Indexing \(c.indexedCount.formatted())"
                               : c.indexingStep)
        case .matching:
            return .simple(name: "Match Audio", icon: "link", isRunning: true,
                           count: c.processedTracks, total: c.totalTracks)
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
        case "Sync":           return .blue
        case "MBID":           return .purple
        case "AcousticBrainz": return .teal
        case "Match Audio":    return .orange
        case "Cues":           return .pink
        case "Export":         return .cyan
        case "Backup":         return .brown
        case "Restore":        return .indigo
        default:               return .accentColor
        }
    }

    /// Progressively smaller bubble rows so a growing button count (9 coming with
    /// "Analyze Audio") degrades by hiding labels, then by scrolling — never by
    /// clipping text mid-word or letter-wrapping it.
    @ViewBuilder
    private var libraryBubbleRow: some View {
        ViewThatFits(in: .horizontal) {
            libraryButtons(showsLabels: true)
            libraryButtons(showsLabels: false)
            ScrollView(.horizontal, showsIndicators: false) {
                libraryButtons(showsLabels: false)
            }
        }
    }

    @ViewBuilder
    private func libraryButtons(showsLabels: Bool) -> some View {
        HStack(spacing: 8) {
            // Clears the sidebar toggle button, which overlaps this row's own
            // leading padding and otherwise clips the "Sync" bubble.
            Color.clear.frame(width: 32, height: 1)
            libraryBubble(title: "Sync",           icon: "arrow.triangle.2.circlepath", showsLabel: showsLabels) { syncOrchestrator.startSync() }
            libraryBubble(title: "MBID",           icon: "magnifyingglass.circle",       showsLabel: showsLabels) { scanCoordinator.start() }
            libraryBubble(title: "AcousticBrainz", icon: "waveform.circle",             showsLabel: showsLabels) { audioFeaturesCoordinator.start() }
            libraryBubble(title: "Match Audio",    icon: "link.circle",
                          disabled: !driveMonitor.isAvailable, showsLabel: showsLabels) { fileMatchCoordinator.startFullScan() }
            libraryBubble(title: "Cues",           icon: "scope",
                          disabled: !driveMonitor.isAvailable, showsLabel: showsLabels) { cueCoordinator.startDetection(scope: .matched) }
            libraryBubble(title: "Export",         icon: "music.note.list",             showsLabel: showsLabels) { triggerExport() }
            libraryBubble(title: "Backup",         icon: "externaldrive.badge.timemachine", showsLabel: showsLabels) { runBackupExport() }
            libraryBubble(title: "Restore",        icon: "arrow.clockwise.icloud",          showsLabel: showsLabels) { runBackupImport() }
        }
    }

    /// Titles of the library bubbles whose coordinator currently has a running
    /// operation, so that bubble can be tinted to point at the matching status
    /// bubble on the right (the only link between the two today is this highlight).
    private var activeLibraryBubbleTitles: Set<String> {
        var active: Set<String> = []
        if syncOrchestrator.isSyncing { active.insert("Sync") }
        if case .scanning = scanCoordinator.phase { active.insert("MBID") }
        if case .scanning = audioFeaturesCoordinator.phase { active.insert("AcousticBrainz") }
        switch fileMatchCoordinator.phase {
        case .indexing, .matching, .generatingWaveforms, .generatingWaveformsPaused:
            active.insert("Match Audio")
        default:
            break
        }
        if cueCoordinator.phase == .detecting { active.insert("Cues") }
        return active
    }

    @ViewBuilder
    private func libraryBubble(title: String, icon: String, disabled: Bool = false, showsLabel: Bool = true, action: @escaping () -> Void) -> some View {
        let tint = bubbleColor(for: title)
        let isActive = activeLibraryBubbleTitles.contains(title)
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(disabled ? Color.secondary : tint)
                if showsLabel {
                    Text(title)
                        .font(.system(size: 12, weight: .medium))
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
        .help(disabled ? "\(title) (unavailable — drive not connected)" : title)
        .accessibilityLabel(disabled ? "\(title) (unavailable — drive not connected)" : title)
    }
}

struct LibraryBubbleButtonStyle: ButtonStyle {
    let tint: Color
    /// True while this bubble's operation is running, so it visibly links to its
    /// status bubble on the right without any other connection between the two.
    var isActive: Bool = false
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
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
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
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .brightness(isHovering ? 0.06 : 0)
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.snappy, value: isHovering)
            .animation(.snappy, value: configuration.isPressed)
            .onHover { hovering in
                isHovering = hovering
            }
    }
}
