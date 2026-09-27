import SwiftUI

struct DriveUnavailableBanner: View {
    @Environment(DriveMonitor.self) private var driveMonitor

    var body: some View {
        if !driveMonitor.isAvailable {
            HStack(spacing: 12) {
                Image(systemName: "externaldrive.badge.xmark")
                    .foregroundStyle(.orange)
                    .font(.title3)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Music library unavailable")
                        .font(.body.weight(.semibold))
                    Text(bannerSubtitle)
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
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private var bannerSubtitle: String {
        let pathPart = driveMonitor.displayPath.isEmpty
            ? "Drive not mounted or NAS unreachable."
            : "Path: \(driveMonitor.displayPath)"
        return "\(pathPart) Match Audio and Cue Detection are disabled."
    }
}
