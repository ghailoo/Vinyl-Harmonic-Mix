import SwiftUI

/// A drawn 12" vinyl record that spins continuously while `isPlaying` is true and
/// freezes at its current angle on pause — no snap-back to zero.
///
/// The center label shows `coverArtURL` via AsyncImage when available, or a plain
/// warm-colored label otherwise. Size is parameterised for reuse at other call sites.
struct SpinningRecordView: View {
    let isPlaying: Bool
    let coverArtURL: URL?
    var diameter: CGFloat = 30

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Spin-state: all @State so they survive re-renders and prop changes.
    @State private var frozenAngle: Double = 0
    @State private var spinStartDate: Date = .now
    @State private var spinStartAngle: Double = 0

    // 33⅓ RPM gives ~200°/s → 1.8 s per revolution. Visually convincing.
    private let secondsPerRevolution: Double = 1.8

    // Fixed groove-ring fractions of the diameter (innermost to outermost).
    private static let grooveFractions: [Double] = [0.84, 0.76, 0.67, 0.58, 0.49]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !isPlaying || reduceMotion)) { context in
            let angle: Double = {
                guard isPlaying, !reduceMotion else { return frozenAngle }
                let elapsed = context.date.timeIntervalSince(spinStartDate)
                return spinStartAngle + (elapsed / secondsPerRevolution) * 360.0
            }()
            disc(angle: angle)
        }
        .onChange(of: isPlaying) { _, nowPlaying in
            guard !reduceMotion else { return }
            if nowPlaying {
                // Resume: restart the elapsed-time clock from the frozen position.
                spinStartDate  = .now
                spinStartAngle = frozenAngle
            } else {
                // Pause: capture the angle at this exact moment so the record freezes here.
                let elapsed = Date.now.timeIntervalSince(spinStartDate)
                frozenAngle = (spinStartAngle + (elapsed / secondsPerRevolution) * 360.0)
                    .truncatingRemainder(dividingBy: 360.0)
            }
        }
    }

    // MARK: - Record disc

    @ViewBuilder
    private func disc(angle: Double) -> some View {
        let labelDiam   = diameter * 0.38
        let spindleDiam = max(2.5, diameter * 0.055)

        ZStack {
            // ① Outer black disc
            Circle()
                .fill(Color(white: 0.09))

            // ② Concentric groove rings — subtle lighter circles
            ForEach(Self.grooveFractions, id: \.self) { f in
                Circle()
                    .strokeBorder(Color(white: 0.23), lineWidth: 0.4)
                    .frame(width: diameter * f, height: diameter * f)
            }

            // ③ Center label — cover art if available, warm orange fallback
            ZStack {
                Circle()
                    .fill(Color(red: 0.62, green: 0.38, blue: 0.12))

                if let url = coverArtURL {
                    AsyncImage(url: url) { phase in
                        if case .success(let img) = phase {
                            img.resizable().aspectRatio(contentMode: .fill)
                        }
                    }
                    .clipShape(Circle())
                }

                // ④ Spindle hole at the very centre of the label
                Circle()
                    .fill(Color(white: 0.07))
                    .frame(width: spindleDiam, height: spindleDiam)
            }
            .frame(width: labelDiam, height: labelDiam)
            .clipShape(Circle())
        }
        .frame(width: diameter, height: diameter)
        .rotationEffect(.degrees(angle))
        .shadow(color: .black.opacity(0.35), radius: 2, x: 0, y: 1)
    }
}
