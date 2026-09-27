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

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Tracks the last rendered label and when it last changed. Lives here (not in the
    /// six coordinators) so it's a pure presentation concern: SwiftUI preserves this
    /// @State across re-renders as long as the bubble's identity (status.name in the
    /// parent's ForEach) stays the same, i.e. for as long as the operation keeps running.
    @State private var lastLabel: String = ""
    @State private var lastChangeDate: Date = .now

    private static let stallThreshold: TimeInterval = 30

    var body: some View {
        if status.isRunning {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let elapsed = context.date.timeIntervalSince(lastChangeDate)
                bubbleContent(isStalled: elapsed > Self.stallThreshold, elapsed: elapsed)
            }
            .onAppear {
                lastLabel = label
                lastChangeDate = .now
            }
            .onChange(of: label) { _, newValue in
                guard newValue != lastLabel else { return }
                lastLabel = newValue
                lastChangeDate = .now
            }
        }
    }

    @ViewBuilder
    private func bubbleContent(isStalled: Bool, elapsed: TimeInterval) -> some View {
        let tint: Color = isStalled ? .orange : .accentColor
        // A phase can legitimately sit on one long file for a while — word this as
        // "no progress", never "crashed"/"stuck", since we can't actually tell the
        // difference from here.
        let isProgressing = status.isRunning && !status.isPaused && !status.isPausing && !isStalled

        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: status.isPaused ? "pause.circle.fill" : status.icon)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(tint)
                    // Gentle continuous rotation while progressing; frozen (isActive:
                    // false) the moment it stalls or reduce-motion is on, so a frozen
                    // icon + amber label together read as "no progress".
                    .symbolEffect(.rotate, options: .repeating, isActive: isProgressing && !reduceMotion)

                Text(isStalled ? "No progress for \(Int(elapsed))s" : label)
                    .font(.callout.weight(.medium).monospacedDigit())
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .fixedSize()
                    .foregroundStyle(isStalled ? Color.orange : Color.primary)

                if let pauseAction = status.pauseAction, !status.isPaused, !status.isPausing {
                    Button(action: pauseAction) {
                        Image(systemName: "pause.fill").font(.caption.weight(.bold))
                    }
                    .buttonStyle(.plain)
                    .help("Pause")
                    .accessibilityLabel("Pause")
                } else if status.isPausing {
                    Image(systemName: "ellipsis")
                        .font(.caption.weight(.bold))
                        .opacity(0.5)
                } else if status.isPaused, let resumeAction = status.resumeAction {
                    Button(action: resumeAction) {
                        Image(systemName: "play.fill").font(.caption.weight(.bold))
                    }
                    .buttonStyle(.plain)
                    .help("Resume")
                    .accessibilityLabel("Resume")
                }
            }

            progressBar(tint: tint, isFrozen: !isProgressing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(tint.opacity(0.12))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(tint.opacity(0.3), lineWidth: 0.5))
        )
    }

    /// Determinate bar when both count and total are known; otherwise an indeterminate
    /// bar so an unknown-length phase (e.g. indexing) still visibly reads as alive.
    @ViewBuilder
    private func progressBar(tint: Color, isFrozen: Bool) -> some View {
        if let count = status.count, let total = status.total, total > 0 {
            DeterminateBar(fraction: Double(min(count, total)) / Double(total), color: tint)
        } else {
            IndeterminateBar(color: tint, reduceMotion: reduceMotion, isFrozen: isFrozen)
        }
    }

    private var label: String {
        // statusText wins when present: some phases (e.g. Match Audio's indexing
        // sub-steps) set count/total purely to fill the bar while wanting their own
        // exact wording ("Checking 12,000 / 42,353 files") shown instead of a bare
        // "count / total".
        if let statusText = status.statusText {
            return "\(status.name): \(statusText)"
        }
        if let count = status.count, let total = status.total {
            return "\(status.name): \(count) / \(total)"
        }
        return status.name
    }
}

/// Thin fixed-fraction bar for operations where both count and total are known.
private struct DeterminateBar: View {
    let fraction: Double
    let color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12))
                Capsule().fill(color)
                    .frame(width: geo.size.width * min(1, max(0, fraction)))
            }
        }
        .frame(height: 3)
        .animation(.easeInOut(duration: 0.3), value: fraction)
    }
}

/// Bar for operations with no known total — a sliding segment says "still alive"
/// without claiming a completion percentage it doesn't have. Freezes in place (no
/// motion) when reduce-motion is on or the operation has stalled/paused.
private struct IndeterminateBar: View {
    let color: Color
    let reduceMotion: Bool
    let isFrozen: Bool
    @State private var slide = false

    private var animates: Bool { !reduceMotion && !isFrozen }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12))
                Capsule().fill(color.opacity(0.8))
                    .frame(width: geo.size.width * 0.35)
                    .offset(x: animates
                        ? (slide ? geo.size.width * 0.65 : -geo.size.width * 0.35)
                        : geo.size.width * 0.325)
            }
        }
        .frame(height: 3)
        .clipShape(Capsule())
        .onAppear { restartIfNeeded() }
        .onChange(of: animates) { _, _ in restartIfNeeded() }
    }

    private func restartIfNeeded() {
        guard animates else {
            withAnimation(.easeInOut(duration: 0.2)) { slide = false }
            return
        }
        withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
            slide = true
        }
    }
}
