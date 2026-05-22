import SwiftUI
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
                    .font(.system(size: 13, weight: .semibold))
            }

            Text("\(progress.audioFilesFound.formatted()) audio files found")
                .font(.system(size: 12).monospacedDigit())

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

struct SettingsView: View {
    @Environment(SettingsViewModel.self) private var settings
    @Environment(FileMatchCoordinator.self) private var fileMatchCoordinator
    @Environment(FingerprintScanCoordinator.self) private var fingerprintCoordinator
    @Environment(\.dismiss) private var dismiss

    @State private var mbSavedConfirmation = false

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
    }
}
