import SwiftUI

struct SettingsView: View {
    @Environment(SettingsViewModel.self) private var settings
    @Environment(\.dismiss) private var dismiss

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
                HStack {
                    Button("Test Connection") {
                        Task { await settings.testMBConnection() }
                    }
                    .disabled(settings.mbIsTesting)

                    if settings.mbIsTesting {
                        ProgressView()
                            .padding(.leading, 4)
                    }
                }
            }

            if let message = settings.mbSuccessMessage {
                Section {
                    Label(message, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }

            if let error = settings.mbErrorMessage {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
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
