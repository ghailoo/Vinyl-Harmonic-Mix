import SwiftUI

// MARK: - Harmonic compatibility group

enum HarmonicGroup: String, CaseIterable {
    case perfectMatch = "Perfect match"
    case energyBoost  = "Energy boost"
    case energyDrop   = "Energy drop"
    case moodSwitch   = "Mood switch"

    var systemImage: String {
        switch self {
        case .perfectMatch: return "checkmark.circle.fill"
        case .energyBoost:  return "arrow.up.circle"
        case .energyDrop:   return "arrow.down.circle"
        case .moodSwitch:   return "arrow.left.arrow.right.circle"
        }
    }

    var color: Color {
        switch self {
        case .perfectMatch: return Color(red: 0.15, green: 0.55, blue: 0.30)
        case .energyBoost:  return .orange
        case .energyDrop:   return .blue
        case .moodSwitch:   return .purple
        }
    }
}

// MARK: - Compatible item

struct CompatibleItem: Identifiable {
    var id: String { track.id }
    let track: MixTrack
    let bpmDelta: Double
}

// MARK: - Compatibility engine

enum HarmonicCompatibility {
    static func compatibleGroups(
        for selected: MixTrack,
        in pool: [MixTrack],
        bpmTolerance: Double
    ) -> [HarmonicGroup: [CompatibleItem]] {
        guard !selected.camelot.isEmpty else { return [:] }
        let compat = CamelotConverter.compatibleCodes(for: selected.camelot)
        // compat[0] = same number, other letter → mood switch
        // compat[1] = next number, same letter  → energy boost
        // compat[2] = prev number, same letter  → energy drop

        var result: [HarmonicGroup: [CompatibleItem]] = [:]
        for track in pool {
            guard track.id != selected.id else { continue }
            let delta = track.bpm - selected.bpm
            guard abs(delta) <= bpmTolerance else { continue }

            let group: HarmonicGroup
            if track.camelot == selected.camelot {
                group = .perfectMatch
            } else if compat.count >= 3 && track.camelot == compat[1] {
                group = .energyBoost
            } else if compat.count >= 3 && track.camelot == compat[2] {
                group = .energyDrop
            } else if !compat.isEmpty && track.camelot == compat[0] {
                group = .moodSwitch
            } else {
                continue
            }

            result[group, default: []].append(CompatibleItem(track: track, bpmDelta: delta))
        }
        for key in result.keys {
            result[key]?.sort { abs($0.bpmDelta) < abs($1.bpmDelta) }
        }
        return result
    }
}
