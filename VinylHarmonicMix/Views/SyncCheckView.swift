import SwiftUI

/// Stage-1 sync test UI: detect new Discogs releases and additively import them.
/// Presented as a sheet from the Collection toolbar. Never deletes existing data.
struct SyncCheckView: View {
    @Environment(CollectionViewModel.self) private var viewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Sync with Discogs")
                .font(.title2.bold())

            phaseContent

            Spacer()
        }
        .padding(24)
        .frame(minWidth: 400, minHeight: 220)
        .onDisappear { viewModel.resetSyncPhase() }
    }

    @ViewBuilder
    private var phaseContent: some View {
        switch viewModel.syncPhase {
        case .idle:
            VStack(alignment: .leading, spacing: 12) {
                Text("Compares your live Discogs collection with what's stored locally and finds newly added releases. Existing releases, track data, file matches, and harmonic analysis are never touched.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Check for new releases") {
                    Task { await viewModel.checkForNewReleases() }
                }
                .buttonStyle(.borderedProminent)
            }

        case .checking:
            HStack(spacing: 10) {
                ProgressView()
                Text("Fetching collection from Discogs…")
                    .foregroundStyle(.secondary)
            }

        case .deltaReady(let delta):
            VStack(alignment: .leading, spacing: 12) {
                if delta.isUpToDate {
                    Label("Collection is up to date", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.headline)
                } else {
                    Label(
                        "\(delta.newIDs.count) new release\(delta.newIDs.count == 1 ? "" : "s") found on Discogs",
                        systemImage: "plus.circle.fill"
                    )
                    .foregroundStyle(.blue)
                    .font(.headline)
                }

                if !delta.removedIDs.isEmpty {
                    Label(
                        "\(delta.removedIDs.count) release\(delta.removedIDs.count == 1 ? "" : "s") removed from Discogs (not deleted locally — additions only)",
                        systemImage: "info.circle"
                    )
                    .foregroundStyle(.secondary)
                    .font(.callout)
                }

                Text("Discogs: \(delta.remoteCount) · Local: \(delta.localCount)\(delta.newIDs.isEmpty ? "" : " · New: \(delta.newIDs.count)")")
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                HStack(spacing: 10) {
                    if !delta.isUpToDate {
                        Button("Import \(delta.newIDs.count) new release\(delta.newIDs.count == 1 ? "" : "s")") {
                            Task { _ = await viewModel.importNewReleases(newIDs: delta.newIDs) }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    Button("Check again") {
                        Task { await viewModel.checkForNewReleases() }
                    }
                    .buttonStyle(.borderless)
                    if delta.isUpToDate {
                        Button("Done") { dismiss() }
                            .buttonStyle(.bordered)
                    }
                }
            }

        case .importing:
            HStack(spacing: 10) {
                ProgressView()
                Text("Fetching and inserting new releases…")
                    .foregroundStyle(.secondary)
            }

        case .done(let added):
            VStack(alignment: .leading, spacing: 12) {
                if added == 0 {
                    Label("Already up to date — nothing imported", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.headline)
                } else {
                    Label(
                        "\(added) new release\(added == 1 ? "" : "s") added",
                        systemImage: "checkmark.circle.fill"
                    )
                    .foregroundStyle(.green)
                    .font(.headline)
                    Text("Next: run the MBID scan and file-matching pass to enrich the new releases.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
            }

        case .failed(let message):
            VStack(alignment: .leading, spacing: 12) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Try again") {
                    Task { await viewModel.checkForNewReleases() }
                }
                .buttonStyle(.bordered)
            }
        }
    }
}
