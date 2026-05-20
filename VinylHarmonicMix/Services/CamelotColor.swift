import SwiftUI

enum CamelotColor {
    /// Background color for a Camelot wheel pill.
    /// Inner ring (A = minor) uses pale tints; outer ring (B = major) uses saturated versions of the same hue.
    /// Clockwise from 12 o'clock: cyan → green → lime → yellow → orange → red → pink → magenta → purple → violet → blue → cyan.
    static func background(for code: String) -> Color {
        switch code {
        // 12 — Cyan / Teal
        case "12A": return Color(red: 0.78, green: 0.92, blue: 0.95)
        case "12B": return Color(red: 0.52, green: 0.85, blue: 0.89)
        // 1 — Light Green
        case "1A":  return Color(red: 0.80, green: 0.94, blue: 0.86)
        case "1B":  return Color(red: 0.55, green: 0.88, blue: 0.70)
        // 2 — Green
        case "2A":  return Color(red: 0.82, green: 0.94, blue: 0.78)
        case "2B":  return Color(red: 0.62, green: 0.88, blue: 0.55)
        // 3 — Lime / Yellow-Green
        case "3A":  return Color(red: 0.88, green: 0.94, blue: 0.72)
        case "3B":  return Color(red: 0.78, green: 0.88, blue: 0.45)
        // 4 — Yellow
        case "4A":  return Color(red: 0.94, green: 0.92, blue: 0.72)
        case "4B":  return Color(red: 0.93, green: 0.85, blue: 0.45)
        // 5 — Orange
        case "5A":  return Color(red: 0.96, green: 0.86, blue: 0.74)
        case "5B":  return Color(red: 0.95, green: 0.72, blue: 0.45)
        // 6 — Red-Orange
        case "6A":  return Color(red: 0.96, green: 0.78, blue: 0.74)
        case "6B":  return Color(red: 0.94, green: 0.55, blue: 0.45)
        // 7 — Pink-Red
        case "7A":  return Color(red: 0.96, green: 0.76, blue: 0.80)
        case "7B":  return Color(red: 0.93, green: 0.50, blue: 0.60)
        // 8 — Magenta / Pink
        case "8A":  return Color(red: 0.95, green: 0.78, blue: 0.88)
        case "8B":  return Color(red: 0.88, green: 0.48, blue: 0.72)
        // 9 — Purple
        case "9A":  return Color(red: 0.88, green: 0.78, blue: 0.94)
        case "9B":  return Color(red: 0.70, green: 0.45, blue: 0.88)
        // 10 — Violet
        case "10A": return Color(red: 0.80, green: 0.78, blue: 0.95)
        case "10B": return Color(red: 0.55, green: 0.50, blue: 0.90)
        // 11 — Blue
        case "11A": return Color(red: 0.76, green: 0.84, blue: 0.95)
        case "11B": return Color(red: 0.45, green: 0.62, blue: 0.92)
        default:    return Color.gray.opacity(0.3)
        }
    }

    /// Foreground (text) color for the pill.
    /// A codes are pale → black text. Most B codes are saturated → white text,
    /// except the lighter greens/yellows/cyan which still read fine with black.
    static func text(for code: String) -> Color {
        if code.hasSuffix("A") { return .black }
        switch code {
        case "1B", "2B", "3B", "4B", "12B": return .black
        default: return .white
        }
    }
}
