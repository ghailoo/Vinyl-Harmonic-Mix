import SwiftUI
import SwiftData
#if os(macOS)
import AppKit
#endif

private struct LibraryScanProgressPanel: View {
    let progress: SettingsViewModel.LibraryScanProgress
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if progress.isComplete {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(progress.isComplete ? "Scan complete" : "Scanning local library…")
                    .font(.body.weight(.semibold))
            }

            Text("\(progress.audioFilesFound.formatted()) audio files found")
                .font(.callout.monospacedDigit())

            if !progress.isComplete {
                Text("Currently in: \(progress.currentFolder)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(progress.itemsExamined.formatted()) items examined")
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                Button("Cancel", action: onCancel)
                    .controlSize(.small)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct ResetConfirmationSheet: View {
    let onConfirm: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var confirmationText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Reset All Data", systemImage: "exclamationmark.triangle.fill")
                .font(.title2.bold())
                .foregroundStyle(.red)

            Text("This permanently deletes your entire synced collection, MusicBrainz/AcousticBrainz data, local file matches, sets, and cue points from this app. A safety copy of the current data is saved to disk first, but this action cannot be undone from within the app.")

            Text("Your Discogs credentials, AcoustID key, and library folder selection are kept — you will not need to re-enter them.")
                .foregroundStyle(.secondary)

            Text("Type RESET to confirm:")
                .font(.headline)
            TextField("RESET", text: $confirmationText)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
#if os(iOS)
                .textInputAutocapitalization(.characters)
#endif

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Reset All Data", role: .destructive) {
                    onConfirm()
                    dismiss()
                }
                .disabled(confirmationText != "RESET")
            }
        }
        .padding(24)
        .frame(minWidth: 420)
    }
}

struct SettingsView: View {
    @Environment(SettingsViewModel.self) private var settings
    @Environment(FileMatchCoordinator.self) private var fileMatchCoordinator
    @Environment(FingerprintScanCoordinator.self) private var fingerprintCoordinator
    @Environment(LocalAnalysisCoordinator.self) private var localAnalysisCoordinator
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var mbSavedConfirmation = false
    @State private var showResetSheet = false
    @State private var resetCompletion: ResetService.Summary?
    @State private var resetErrorMessage: String?
    @State private var resetFailure: ResetService.ResetError?
    @State private var lastBackup = ResetService.mostRecentBackup()

    var body: some View {
        @Bindable var settings = settings

        Form {
            // MARK: Discogs Account
            Section("Discogs Account") {
                SecureField("Personal Access Token", text: $settings.token)
                TextField("Username", text: $settings.username)
                    .autocorrectionDisabled()
#if os(iOS)
                    .textInputAutocapitalization(.never)
#endif
            }

            Section {
                HStack {
                    Button("Save") {
                        settings.save()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(settings.token.isEmpty)

                    Button("Test Connection") {
                        Task { await settings.testToken() }
                    }
                    .disabled(settings.token.isEmpty || settings.isValidating)

                    if settings.isValidating {
                        ProgressView()
                            .padding(.leading, 4)
                    }
                }
            }

            if let message = settings.successMessage {
                Section {
                    Label(message, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }

            if let error = settings.errorMessage {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }

            // MARK: Local Audio Library
            Section("Local Audio Library") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Library folder")
                        .font(.headline)
                    if settings.localLibraryDisplayPath.isEmpty {
                        Text("Not selected")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(settings.localLibraryDisplayPath)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                }

                HStack(spacing: 8) {
#if os(macOS)
                    Button("Choose folder…") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true
                        panel.canChooseFiles = false
                        panel.allowsMultipleSelection = false
                        panel.message = "Select your music library root folder"
                        panel.prompt = "Select"
                        if panel.runModal() == .OK, let url = panel.url {
                            settings.setLibraryBookmark(from: url)
                        }
                    }
#endif
                    Button("Test access") {
                        settings.testLibraryAccess()
                    }
                    .disabled(settings.localLibraryDisplayPath.isEmpty || settings.isTestingLibrary)
                }

                if let progress = settings.scanProgress {
                    LibraryScanProgressPanel(progress: progress) {
                        settings.cancelLibraryScan()
                    }
                }

                if settings.scanProgress == nil {
                    switch settings.libraryTestStatus {
                    case .idle:
                        EmptyView()
                    case .accessible(let count):
                        Label("Accessible · \(count.formatted()) audio files found",
                              systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    case .unreachable:
                        Label("Cannot access folder — it may be unmounted. Re-select it.",
                              systemImage: "xmark.circle.fill")
                            .foregroundStyle(.red)
                    case .empty:
                        Label("Folder accessible but no audio files found",
                              systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
            }

            Section {
                switch settings.fpcalcStatus {
                case .found(let path):
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Chromaprint found at \(path)", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.caption)

                        HStack(spacing: 8) {
                            Button("Test fpcalc") {
                                Task { await settings.testFpcalcExecution() }
                            }
                            .font(.caption)
                            .disabled(settings.isTestingFpcalc)

                            if settings.isTestingFpcalc {
                                ProgressView().scaleEffect(0.7)
                            }
                        }

                        switch settings.fpcalcExecutionStatus {
                        case .idle:
                            EmptyView()
                        case .success(let version):
                            Label("fpcalc works: \(version)", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .font(.caption)
                        case .blocked(let msg):
                            Label("fpcalc found but cannot execute: \(msg)",
                                  systemImage: "xmark.circle.fill")
                                .foregroundStyle(.red)
                                .font(.caption)
                        }
                    }

                case .notFound:
                    VStack(alignment: .leading, spacing: 2) {
                        Label("Chromaprint (fpcalc) not found",
                              systemImage: "xmark.circle.fill")
                            .foregroundStyle(.red)
                            .font(.caption)
                        Text("Install with: brew install chromaprint")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }

            Section {
                SecureField("AcoustID API key", text: $settings.acoustIDKey)
                    .onSubmit { settings.saveAcoustIDKey() }

                HStack(spacing: 8) {
                    Button("Test API key") {
                        Task { await settings.testAcoustIDKey() }
                    }
                    .disabled(settings.acoustIDKey.isEmpty || settings.isTestingAcoustID)

                    if settings.isTestingAcoustID {
                        ProgressView()
                            .padding(.leading, 4)
                    }
                }

                switch settings.acoustIDTestStatus {
                case .idle:
                    EmptyView()
                case .valid:
                    Label("API key valid", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                case .invalid:
                    Label("Invalid API key", systemImage: "xmark.circle.fill")
                        .foregroundStyle(.red)
                case .networkError(let msg):
                    Label("Could not reach AcoustID: \(msg)",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }

            // MARK: MusicBrainz
            Section("MusicBrainz") {
                Text("No API key required. MusicBrainz allows read-only access without authentication.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextField(
                    "Contact email",
                    text: $settings.mbContactEmail,
                    prompt: Text("your-email@example.com (optional)")
                )
                .autocorrectionDisabled()
#if os(iOS)
                .textInputAutocapitalization(.never)
                .keyboardType(.emailAddress)
#endif
                .onSubmit { settings.save() }

                Text("Embedded in requests to identify this app. Helps the MusicBrainz team contact you if there's a problem with your usage. Leave blank to use the default.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Section {
                HStack(spacing: 8) {
                    Button("Save") {
                        settings.save()
                        settings.mbSuccessMessage = nil
                        settings.mbErrorMessage = nil
                        mbSavedConfirmation = true
                        Task {
                            try? await Task.sleep(for: .seconds(3))
                            mbSavedConfirmation = false
                        }
                    }
                    .buttonStyle(.borderedProminent)

                    Button("Test Connection") {
                        mbSavedConfirmation = false
                        Task { await settings.testMBConnection() }
                    }
                    .buttonStyle(.bordered)
                    .disabled(settings.mbIsTesting)

                    if settings.mbIsTesting {
                        ProgressView()
                            .padding(.leading, 4)
                    }
                }

                if mbSavedConfirmation {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                        Text("Saved")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if let message = settings.mbSuccessMessage {
                    Label(message, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else if let error = settings.mbErrorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }
            // MARK: Name Matching
            Section("Name Matching") {
                Text("Match collection tracks to local audio files by title and artist (string matching, no fingerprinting). Fast — completes in seconds.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    Button("Test match (first 150)") {
                        fileMatchCoordinator.startTestBatch()
                    }
                    .disabled(fileMatchCoordinator.phase != .idle &&
                              fileMatchCoordinator.phase != .completed &&
                              fileMatchCoordinator.phase != .cancelled)

                    Button("Match all tracks") {
                        fileMatchCoordinator.startFullScan()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(fileMatchCoordinator.phase != .idle &&
                              fileMatchCoordinator.phase != .completed &&
                              fileMatchCoordinator.phase != .cancelled)
                }

                if fileMatchCoordinator.shouldShowPanel {
                    FileMatchPanelView(coordinator: fileMatchCoordinator)
                }
            }

            // MARK: Local Essentia Analysis
            Section("Local Audio Analysis (Essentia)") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Extracts BPM and key from local audio files using Essentia (native arm64). Scope: confident-matched tracks with no local analysis yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("python3: \(LocalAnalysisCoordinator.python3Path)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                    Text("Script: \(LocalAnalysisCoordinator.scriptPath)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.head)
                }

                essentiaProvisioningView
            }

            // MARK: AcoustID Fingerprint Matching
            Section("AcoustID Fingerprint Matching") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Resolve version-ambiguous review matches by fingerprinting the audio.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Slower (~3 tracks/sec). Scope: \(fingerprintCoordinator.reviewCount) review tracks.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 8) {
                    Button("Test (first 10)") {
                        fingerprintCoordinator.startTestBatch()
                    }
                    .disabled(!fingerprintCoordinator.phase.isIdle)

                    Button("Fingerprint review tracks") {
                        fingerprintCoordinator.startScan()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!fingerprintCoordinator.phase.isIdle ||
                              fingerprintCoordinator.reviewCount == 0)
                }

                if fingerprintCoordinator.shouldShowPanel {
                    FingerprintScanPanelView(coordinator: fingerprintCoordinator)
                }
            }

            // MARK: Danger Zone
            Section("Danger Zone") {
                if let lastBackup {
                    Label(
                        "Last safety backup: \(lastBackup.url.lastPathComponent) (\(lastBackup.date.formatted(date: .abbreviated, time: .shortened)))",
                        systemImage: "checkmark.circle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Button("Reset All Data…", role: .destructive) {
                    showResetSheet = true
                }

                if let error = resetErrorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.caption)
                }
            }
        }
        .navigationTitle("Settings")
#if os(macOS)
        .formStyle(.grouped)
#endif
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
#if os(macOS)
        .background {
            // Lets Esc close the sheet on macOS without showing a second button
            Button("", action: { dismiss() })
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .allowsHitTesting(false)
        }
#endif
        .sheet(isPresented: $showResetSheet) {
            ResetConfirmationSheet(onConfirm: performReset)
        }
        .alert("Reset Complete", isPresented: Binding(
            get: { resetCompletion != nil },
            set: { if !$0 { resetCompletion = nil } }
        )) {
            Button("OK") { }
#if os(macOS)
            Button("Show in Finder") {
                if let folder = resetCompletion?.backupFolder {
                    NSWorkspace.shared.activateFileViewerSelecting([folder])
                }
            }
#endif
        } message: {
            if let resetCompletion {
                Text("All data was cleared. A safety backup (\(resetCompletion.matchesBackedUp) matches) was saved to:\n\(resetCompletion.backupFolder.path)")
            }
        }
        .alert("Reset Failed — Data Was NOT Deleted", isPresented: Binding(
            get: { resetFailure != nil },
            set: { if !$0 { resetFailure = nil } }
        )) {
            Button("OK") { }
#if os(macOS)
            Button("Show Backup in Finder") {
                if case .deletionFailed(let folder, _) = resetFailure {
                    NSWorkspace.shared.activateFileViewerSelecting([folder])
                }
            }
#endif
        } message: {
            if let resetFailure {
                Text(resetFailure.errorDescription ?? "Reset failed.")
            }
        }
    }

    private func performReset() {
        do {
            let summary = try ResetService.performReset(modelContext: modelContext)
            resetErrorMessage = nil
            lastBackup = (summary.backupFolder, .now)
            resetCompletion = summary
        } catch let error as ResetService.ResetError {
            // Deletion failed after the backup was already written — the data is untouched.
            resetErrorMessage = nil
            resetFailure = error
        } catch {
            resetErrorMessage = "Reset failed before any backup was completed: \(error.localizedDescription)"
        }
    }

    // MARK: - Essentia provisioning UI

    @ViewBuilder
    private var essentiaProvisioningView: some View {
        let status = localAnalysisCoordinator.essentiaStatus

        switch status {

        case .unknown:
            Button("Test Essentia") { localAnalysisCoordinator.testEssentia() }

        case .testing:
            HStack(spacing: 8) {
                ProgressView().scaleEffect(0.7)
                Text("Testing…").font(.caption).foregroundStyle(.secondary)
            }

        case .installed(let ver):
            Label(ver, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green).font(.caption)

        case .notInstalled:
            VStack(alignment: .leading, spacing: 8) {
                Label("Essentia not installed for \(LocalAnalysisCoordinator.python3Path)",
                      systemImage: "xmark.circle.fill")
                    .foregroundStyle(.orange).font(.caption)
                Button("Install Essentia") { localAnalysisCoordinator.installEssentia() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                Text("Runs: \(LocalAnalysisCoordinator.python3Path) -m pip install --break-system-packages essentia")
                    .font(.caption2).foregroundStyle(.tertiary).textSelection(.enabled)
            }

        case .installing:
            HStack(spacing: 8) {
                ProgressView().scaleEffect(0.7)
                Text("Installing Essentia… (this can take a minute)")
                    .font(.caption).foregroundStyle(.secondary)
            }

        case .installFailed(let reason):
            VStack(alignment: .leading, spacing: 8) {
                Label("Install failed", systemImage: "xmark.circle.fill")
                    .foregroundStyle(.red).font(.caption)
                Text(reason)
                    .font(.caption2).foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(6)
                HStack(spacing: 8) {
                    Button("Retry install") { localAnalysisCoordinator.installEssentia() }
                        .controlSize(.small)
                    Button("Re-test") { localAnalysisCoordinator.testEssentia() }
                        .controlSize(.small)
                }
            }

        case .testFailed(let reason):
            VStack(alignment: .leading, spacing: 8) {
                Label("Test failed", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red).font(.caption)
                Text(reason)
                    .font(.caption2).foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(4)
                Button("Retry test") { localAnalysisCoordinator.testEssentia() }
                    .controlSize(.small)
            }
        }
    }
}
