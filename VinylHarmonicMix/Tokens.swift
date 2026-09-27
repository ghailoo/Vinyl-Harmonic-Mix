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
