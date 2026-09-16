import SwiftUI

struct OperationStatus {
    let name: String
    let icon: String
    let isRunning: Bool
    let count: Int?
    let total: Int?
    let statusText: String?
    let pauseAction: (() -> Void)?
    let resumeAction: (() -> Void)?
    let isPaused: Bool
    let isPausing: Bool

    static func simple(name: String, icon: String, isRunning: Bool,
                       count: Int? = nil, total: Int? = nil,
                       statusText: String? = nil) -> OperationStatus {
        OperationStatus(name: name, icon: icon, isRunning: isRunning,
                        count: count, total: total, statusText: statusText,
                        pauseAction: nil, resumeAction: nil,
                        isPaused: false, isPausing: false)
    }
}

struct OperationStatusBubble: View {
    let status: OperationStatus

    var body: some View {
        if status.isRunning {
            HStack(spacing: 6) {
                Image(systemName: status.isPaused ? "pause.circle.fill" : status.icon)
                    .font(.system(size: 12, weight: .medium))

                Text(label)
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .lineLimit(1)
                    .truncationMode(.middle)

                if let pauseAction = status.pauseAction, !status.isPaused, !status.isPausing {
                    Button(action: pauseAction) {
                        Image(systemName: "pause.fill").font(.system(size: 10, weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .help("Pause")
                    .accessibilityLabel("Pause")
                } else if status.isPausing {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 10, weight: .bold))
                        .opacity(0.5)
                } else if status.isPaused, let resumeAction = status.resumeAction {
                    Button(action: resumeAction) {
                        Image(systemName: "play.fill").font(.system(size: 10, weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .help("Resume")
                    .accessibilityLabel("Resume")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(Color.accentColor.opacity(0.12))
                    .overlay(Capsule().stroke(Color.accentColor.opacity(0.3), lineWidth: 0.5))
            )
        }
    }

    private var label: String {
        if let count = status.count, let total = status.total {
            return "\(status.name): \(count) / \(total)"
        }
        if let statusText = status.statusText {
            return "\(status.name): \(statusText)"
        }
        return status.name
    }
}
