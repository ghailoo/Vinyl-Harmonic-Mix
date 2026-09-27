import SwiftUI

// MARK: - Type scale
//
// Use SwiftUI semantic styles directly; add a `.weight()` / `.monospacedDigit()` as needed.
// macOS point sizes in brackets. Never hardcode `.system(size:)`.
//
//   .largeTitle  [26]  page titles
//   .title       [22]  hero numbers, large section headers
//   .title2      [17]  card / sheet headers
//   .title3      [15]  section headers, prominent row titles
//   .body        [13]  default text  (.headline = 13 bold)
//   .callout     [12]  secondary text — smallest size for readable text
//   .subheadline [11]  badges, pills, pips — smallest size for any text
//   .caption     [10]  icon glyphs only (never text in new code)
//
// Custom entries exist only where no semantic style fits:

extension Font {
    /// Big stat numbers on the Stats page.
    static let statValue = Font.system(size: 32, weight: .bold, design: .rounded)
    /// Inline placeholder / empty-row icons.
    static let iconLarge = Font.system(size: 36)
    /// Full-pane empty-state icons.
    static let iconHero = Font.system(size: 48)
}

// MARK: - Semantic colors
//
// Named by meaning, never by hue. Each has a light and dark variant, resolved by the
// system appearance. Contrast (WCAG, ≥ 4.5:1) checked in both modes:
//   fills        — against the white text drawn on them
//   foregrounds  — against the window background (#FFFFFF/#ECECEC light, #1E1E1E/#323232 dark)

extension Color {
    // Badge fills — always paired with white text
    /// Fully analyzed / complete coverage / local-analysis ("ES") badge.
    static let statusComplete       = adaptive(light: (0.12, 0.50, 0.27), dark: (0.13, 0.45, 0.26))
    /// Partial coverage.
    static let statusPartial        = adaptive(light: (0.66, 0.37, 0.00), dark: (0.66, 0.37, 0.02))
    /// MusicBrainz-identified ("MBID") badge — gradient start / end.
    static let badgeIdentified      = adaptive(light: (0.22, 0.40, 0.85), dark: (0.20, 0.36, 0.76))
    static let badgeIdentifiedEnd   = adaptive(light: (0.45, 0.28, 0.85), dark: (0.41, 0.26, 0.76))
    /// Data from a secondary source (AcousticBrainz, "AB").
    static let badgeSecondarySource = adaptive(light: (0.35, 0.45, 0.65), dark: (0.31, 0.39, 0.56))
    /// Matched local file format pill (MP3, FLAC…).
    static let badgeFileFormat      = adaptive(light: (0.18, 0.42, 0.85), dark: (0.17, 0.38, 0.76))

    // Foregrounds — text and icons on the window background
    /// Perfect harmonic match / positive action.
    static let statusCompleteForeground = adaptive(light: (0.10, 0.48, 0.24), dark: (0.35, 0.80, 0.50))
    /// Waveform cue markers.
    static let cueSwitchIn      = adaptive(light: (0.58, 0.35, 0.00), dark: (1.00, 0.75, 0.05))
    static let cueEnergyRise    = adaptive(light: (0.00, 0.45, 0.36), dark: (0.10, 0.90, 0.70))
    static let cueEnergyFall    = adaptive(light: (0.40, 0.30, 0.85), dark: (0.62, 0.55, 1.00))
    static let cueEnergyNeutral = adaptive(light: (0.36, 0.40, 0.48), dark: (0.60, 0.65, 0.75))

    // ponytail: no light/dark pair — sits on the always-black vinyl, carries no text
    /// Center label of the spinning record when there is no cover art.
    static let recordLabel = Color(red: 0.62, green: 0.38, blue: 0.12)

    private static func adaptive(light: (Double, Double, Double), dark: (Double, Double, Double)) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let (r, g, b) = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
        })
    }
}
