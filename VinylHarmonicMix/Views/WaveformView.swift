import SwiftUI

struct CueMarker: Equatable {
    let timeSec: Double
    let type: String            // "switch_in" | "structural"
    let energyDirection: String // "rise" | "fall" | "neutral" | ""
    let energyDelta: Double     // abs(mean_after - mean_before), normalised 0..1; 0 for switch_in
    var isManual: Bool = false
}

struct WaveformView: View {
    let peaks: [Float]
    var cueMarkers: [CueMarker] = []

    var duration: Double = 0      // track duration in seconds (for time→x mapping)
    var colors: Data? = nil       // 4000 × 3 × Float32 [R,G,B] per bucket; nil = grey fallback
    let onSeek: (Double) -> Void
    var onAddCue: ((Double, String, String) -> Void)? = nil   // (fraction, type, energyDirection)
    var onDeleteCue: ((Double) -> Void)? = nil                // timeSec of cue to remove
    var onMoveCue: ((Double, Double) -> Void)? = nil          // (oldTimeSec, newTimeSec)

    @State private var hoverFraction: Double = 0
    @State private var draggedMarkerTimeSec: Double? = nil
    @State private var dragLiveFraction: Double = 0

    private var nearbyMarker: CueMarker? {
        guard duration > 0, !cueMarkers.isEmpty else { return nil }
        let clickTime = hoverFraction * duration
        let threshold = max(2.0, duration * 0.015)
        guard let closest = cueMarkers.min(by: { abs($0.timeSec - clickTime) < abs($1.timeSec - clickTime) }),
              abs(closest.timeSec - clickTime) <= threshold else { return nil }
        return closest
    }

    private func fmtTime(_ s: Double) -> String {
        let t = max(0, Int(s)); return String(format: "%d:%02d", t / 60, t % 60)
    }

    var body: some View {
        GeometryReader { geo in
            Canvas { ctx, size in
                drawBars(ctx: ctx, size: size)
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                if case .active(let loc) = phase {
                    hoverFraction = max(0, min(1, Double(loc.x / geo.size.width)))
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if draggedMarkerTimeSec == nil {
                            // Hit-test startLocation against marker stems (±8 px)
                            if duration > 0, !cueMarkers.isEmpty {
                                let startX = value.startLocation.x
                                let hitRadius: CGFloat = 8
                                if let closest = cueMarkers.min(by: {
                                    abs(geo.size.width * CGFloat($0.timeSec / duration) - startX) <
                                    abs(geo.size.width * CGFloat($1.timeSec / duration) - startX)
                                }) {
                                    let markerX = geo.size.width * CGFloat(closest.timeSec / duration)
                                    if abs(markerX - startX) <= hitRadius {
                                        draggedMarkerTimeSec = closest.timeSec
                                        dragLiveFraction = max(0, min(1, Double(value.location.x / geo.size.width)))
                                        return
                                    }
                                }
                            }
                            // No marker hit — seek as before
                            onSeek(max(0, min(1, Double(value.location.x / geo.size.width))))
                        } else {
                            // Marker drag in progress — follow cursor live
                            dragLiveFraction = max(0, min(1, Double(value.location.x / geo.size.width)))
                        }
                    }
                    .onEnded { value in
                        if let oldTimeSec = draggedMarkerTimeSec {
                            let newFraction = max(0, min(1, Double(value.location.x / geo.size.width)))
                            let newTimeSec = newFraction * duration
                            onMoveCue?(oldTimeSec, newTimeSec)
                            draggedMarkerTimeSec = nil
                            dragLiveFraction = 0
                        }
                    }
            )
            .contextMenu {
                Button("Add Switch-In")    { onAddCue?(hoverFraction, "switch_in",  "") }
                Button("Add Rise ↑")      { onAddCue?(hoverFraction, "structural", "rise") }
                Button("Add Fall ↓")      { onAddCue?(hoverFraction, "structural", "fall") }
                Button("Add Breakdown •") { onAddCue?(hoverFraction, "structural", "neutral") }
                if let nearby = nearbyMarker {
                    Divider()
                    Button("Delete cue at \(fmtTime(nearby.timeSec))", role: .destructive) {
                        onDeleteCue?(nearby.timeSec)
                    }
                }
            }
        }
    }

    private func drawBars(ctx: GraphicsContext, size: CGSize) {
        guard !peaks.isEmpty else { return }

        let displayStride = 5
        let displayCount  = CGFloat((peaks.count + displayStride - 1) / displayStride)
        let barWidth      = size.width / displayCount
        let midY = size.height / 2

        // Decode per-bar color floats once. Size mismatch or nil → grey fallback.
        let expectedColorBytes = peaks.count * 3 * MemoryLayout<Float>.size
        let colorFloats: [Float]?
        if let data = colors, data.count == expectedColorBytes {
            let floatCount = data.count / MemoryLayout<Float>.size
            colorFloats = data.withUnsafeBytes { ptr in
                Array(ptr.bindMemory(to: Float.self).prefix(floatCount))
            }
        } else {
            colorFloats = nil
        }

        if let cf = colorFloats {
            // Colored path: per-bar Path + fill.
            // Per-bar cost is fine here — .equatable() gate ensures drawBars only fires
            // on legitimate change (track switch, cue edit, zoom), not 50×/sec.
            for rawI in Swift.stride(from: 0, to: peaks.count, by: displayStride) {
                let displayI  = rawI / displayStride
                let peak      = peaks[rawI]
                let x         = CGFloat(displayI) * barWidth
                let barHeight = max(2, CGFloat(peak) * size.height * 0.85)
                let gap       = max(0.75, barWidth * 0.15)
                let rect      = CGRect(x: x + gap, y: midY - barHeight / 2,
                                       width: max(1, barWidth - gap * 2), height: barHeight)
                let base = rawI * 3
                ctx.fill(Path(rect), with: .color(Color(
                    red:   Double(cf[base]),
                    green: Double(cf[base + 1]),
                    blue:  Double(cf[base + 2])
                )))
            }
        } else {
            // Fast path: single accumulated Path, one fill (unchanged from grey optimization).
            let barShading = GraphicsContext.Shading.color(.secondary.opacity(0.35))
            var barPath = Path()
            for rawI in Swift.stride(from: 0, to: peaks.count, by: displayStride) {
                let displayI  = rawI / displayStride
                let peak      = peaks[rawI]
                let x         = CGFloat(displayI) * barWidth
                let barHeight = max(2, CGFloat(peak) * size.height * 0.85)
                let gap       = max(0.75, barWidth * 0.15)
                barPath.addRect(CGRect(
                    x: x + gap,
                    y: midY - barHeight / 2,
                    width: max(1, barWidth - gap * 2),
                    height: barHeight
                ))
            }
            ctx.fill(barPath, with: barShading)
        }

        // Cue markers — drawn on top of bars
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
            let x: CGFloat = (draggedMarkerTimeSec == marker.timeSec)
                ? size.width * CGFloat(dragLiveFraction)
                : size.width * CGFloat(marker.timeSec / duration)
            let stemRect = CGRect(x: max(0, x - 0.625), y: 0, width: 1.25, height: size.height)
            ctx.fill(Path(stemRect), with: .color(color))
            if marker.isManual {
                ctx.fill(Path(ellipseIn: CGRect(x: x - 3, y: size.height - 7, width: 6, height: 6)),
                         with: .color(color))
            }
        }

        // Switch-in — top layer, 1.5px amber stem + downward ▼ flag
        for (marker, _) in visible where marker.type == "switch_in" {
            let x: CGFloat = (draggedMarkerTimeSec == marker.timeSec)
                ? size.width * CGFloat(dragLiveFraction)
                : size.width * CGFloat(marker.timeSec / duration)
            let stemRect = CGRect(x: max(0, x - 0.75), y: 0, width: 1.5, height: size.height)
            ctx.fill(Path(stemRect), with: .color(amber))
            var flag = Path()
            flag.move(to: CGPoint(x: x - 5, y: 0))
            flag.addLine(to: CGPoint(x: x + 5, y: 0))
            flag.addLine(to: CGPoint(x: x, y: 8))
            flag.closeSubpath()
            ctx.fill(flag, with: .color(amber))
            if marker.isManual {
                ctx.fill(Path(ellipseIn: CGRect(x: x - 3, y: size.height - 7, width: 6, height: 6)),
                         with: .color(amber))
            }
        }

        // Labels — drawn last, chronological across all visible cues
        for (i, (marker, color)) in visible.enumerated() {
            let x: CGFloat = (draggedMarkerTimeSec == marker.timeSec)
                ? size.width * CGFloat(dragLiveFraction)
                : size.width * CGFloat(marker.timeSec / duration)

            if marker.type == "switch_in" {
                ctx.draw(
                    Text("\(i + 1)")
                        .font(.system(size: 8, weight: .bold).monospacedDigit())
                        .foregroundStyle(color),
                    at: CGPoint(x: x, y: 14),
                    anchor: .center
                )
            } else {
                let arrowAndDelta: String
                switch marker.energyDirection {
                case "rise":
                    let s = String(format: "%.2f", min(marker.energyDelta, 0.99))
                    arrowAndDelta = "↑" + (s.hasPrefix("0") ? String(s.dropFirst()) : s)
                case "fall":
                    let s = String(format: "%.2f", min(marker.energyDelta, 0.99))
                    arrowAndDelta = "↓" + (s.hasPrefix("0") ? String(s.dropFirst()) : s)
                default:
                    arrowAndDelta = "•"
                }
                ctx.draw(
                    Text("\(i + 1)\(arrowAndDelta)")
                        .font(.system(size: 8, weight: .bold).monospacedDigit())
                        .foregroundStyle(color),
                    at: CGPoint(x: x, y: 5),
                    anchor: .center
                )
            }
        }
    }
}

extension WaveformView: Equatable {
    // Closures intentionally excluded. This is only safe while the closures capture nothing
    // that changes independently of peaks/cueMarkers/duration/colors. If you add a closure
    // that captures volatile state, add that state to this comparison or this view will
    // silently fail to redraw.
    static func == (lhs: WaveformView, rhs: WaveformView) -> Bool {
        lhs.peaks == rhs.peaks &&
        lhs.cueMarkers == rhs.cueMarkers &&
        lhs.duration == rhs.duration &&
        lhs.colors == rhs.colors
    }
}
