import SwiftUI

struct CueMarker {
    let timeSec: Double
    let type: String            // "switch_in" | "structural"
    let energyDirection: String // "rise" | "fall" | "neutral" | ""
}

struct WaveformView: View {
    let peaks: [Float]
    let progress: Double          // 0…1, current playhead position
    var cueMarkers: [CueMarker] = []
    var duration: Double = 0      // track duration in seconds (for time→x mapping)
    let onSeek: (Double) -> Void  // last so trailing-closure callers without cue data still compile

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

        // Cue markers — drawn on top of bars + playhead
        guard duration > 0, !cueMarkers.isEmpty else { return }

        let amber = Color(red: 1.0, green: 0.75, blue: 0.05)
        let switchInTimes = cueMarkers.filter { $0.type == "switch_in" }.map(\.timeSec)

        func structuralColor(_ dir: String) -> Color {
            switch dir {
            case "rise":  return Color(red: 0.1,  green: 0.9,  blue: 0.7)
            case "fall":  return Color(red: 0.55, green: 0.45, blue: 1.0)
            default:      return Color(red: 0.6,  green: 0.65, blue: 0.75)
            }
        }

        // Build chronologically sorted visible marker list (suppressed structurals excluded)
        var visible: [(marker: CueMarker, color: Color)] = []
        for marker in cueMarkers where marker.type == "structural" {
            guard marker.timeSec >= 0, marker.timeSec <= duration else { continue }
            if switchInTimes.contains(where: { abs($0 - marker.timeSec) < 2.0 }) { continue }
            visible.append((marker, structuralColor(marker.energyDirection)))
        }
        for marker in cueMarkers where marker.type == "switch_in" {
            guard marker.timeSec >= 0, marker.timeSec <= duration else { continue }
            visible.append((marker, amber))
        }
        visible.sort { $0.marker.timeSec < $1.marker.timeSec }

        // Structural ticks — bottom layer, 1.25px, full opacity
        for (marker, color) in visible where marker.type == "structural" {
            let x = size.width * CGFloat(marker.timeSec / duration)
            let stemRect = CGRect(x: max(0, x - 0.625), y: 0, width: 1.25, height: size.height)
            ctx.fill(Path(stemRect), with: .color(color))
        }

        // Switch-in — top layer, 1.5px amber stem + downward ▼ flag
        for (marker, _) in visible where marker.type == "switch_in" {
            let x = size.width * CGFloat(marker.timeSec / duration)
            let stemRect = CGRect(x: max(0, x - 0.75), y: 0, width: 1.5, height: size.height)
            ctx.fill(Path(stemRect), with: .color(amber))
            var flag = Path()
            flag.move(to: CGPoint(x: x - 5, y: 0))
            flag.addLine(to: CGPoint(x: x + 5, y: 0))
            flag.addLine(to: CGPoint(x: x, y: 8))
            flag.closeSubpath()
            ctx.fill(flag, with: .color(amber))
        }

        // Number labels — drawn last, chronological across all visible cues
        for (i, (marker, color)) in visible.enumerated() {
            let x = size.width * CGFloat(marker.timeSec / duration)
            // switch_in: below the flag (flag ends at y≈8); structural: near top edge
            let labelY: CGFloat = marker.type == "switch_in" ? 14 : 5
            ctx.draw(
                Text("\(i + 1)")
                    .font(.system(size: 8, weight: .bold).monospacedDigit())
                    .foregroundStyle(color),
                at: CGPoint(x: x, y: labelY),
                anchor: .center
            )
        }
    }
}
