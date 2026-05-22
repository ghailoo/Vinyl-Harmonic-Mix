import SwiftUI

struct WaveformView: View {
    let peaks: [Float]
    let progress: Double    // 0…1, current playhead position
    let onSeek: (Double) -> Void

    var body: some View {
        GeometryReader { geo in
            Canvas { ctx, size in
                drawBars(ctx: ctx, size: size)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let fraction = Double(value.location.x / geo.size.width)
                        onSeek(max(0, min(1, fraction)))
                    }
            )
        }
    }

    private func drawBars(ctx: GraphicsContext, size: CGSize) {
        guard !peaks.isEmpty else { return }

        let count = CGFloat(peaks.count)
        let barWidth = size.width / count
        let midY = size.height / 2
        let playedX = size.width * CGFloat(progress)

        for (i, peak) in peaks.enumerated() {
            let x = CGFloat(i) * barWidth
            let barHeight = max(2, CGFloat(peak) * size.height * 0.85)
            let gap = barWidth * 0.12

            let rect = CGRect(
                x: x + gap,
                y: midY - barHeight / 2,
                width: max(1, barWidth - gap * 2),
                height: barHeight
            )

            let color: Color = x < playedX
                ? .accentColor
                : .secondary.opacity(0.35)
            ctx.fill(Path(rect), with: .color(color))
        }

        // Playhead — thin white line at current position
        if progress > 0 && progress < 1 {
            let lineRect = CGRect(
                x: max(0, playedX - 1),
                y: 0,
                width: 2,
                height: size.height
            )
            ctx.fill(Path(lineRect), with: .color(.white.opacity(0.85)))
        }
    }
}
