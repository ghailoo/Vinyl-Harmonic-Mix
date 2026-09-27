import SwiftUI

struct DriveUnavailableBanner: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(DriveMonitor.self) private var driveMonitor

    var body: some View {
        let missing = driveMonitor.missingFolders
        if !missing.isEmpty {
            HStack(spacing: 12) {
                Image(systemName: "externaldrive.badge.xmark")
                    .foregroundStyle(.orange)
                    .font(.title3)

                VStack(alignment: .leading, spacing: 2) {
                    Text(driveMonitor.isAvailable
                         ? "\(missing.count) of \(driveMonitor.folders.count) library folders unreachable"
                         : "Music library unavailable")
                        .font(.body.weight(.semibold))
                    Text(missing.map(\.displayPath).joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                    Text(driveMonitor.isAvailable
                         ? "Link Files, Detect BPM/Key and Find Cues run on the reachable folders and skip these. Their files and matches are kept."
                         : "Link Files, Detect BPM/Key and Find Cues are disabled. Files and matches are kept.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer()

                Button("Retry") {
                    driveMonitor.refreshAvailability()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color.orange.opacity(0.10))
            .overlay(alignment: .bottom) { Divider() }
            .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
        }
    }
}
