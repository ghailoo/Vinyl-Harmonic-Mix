import SwiftUI

// MARK: - Harmonic compatibility group

enum HarmonicGroup: String, CaseIterable {
    case perfectMatch = "Perfect match"
    case energyBoost  = "Energy boost"
    case energyDrop   = "Energy drop"
    case moodSwitch   = "Mood switch"

    var shortName: String {
        switch self {
        case .perfectMatch: return "Perfect"
        case .energyBoost:  return "Energy+"
        case .energyDrop:   return "Energy−"
        case .moodSwitch:   return "Mood"
        }
    }

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

// MARK: - Blend grade

enum BlendGrade {
    case perfect   // harmonic + BPM ≤ 3%
    case good      // harmonic + BPM ≤ 6%
    case workable  // harmonic but BPM > 6%, OR BPM ≤ 6% but not harmonic
    case hardCut   // neither

    var label: String {
        switch self {
        case .perfect:  return "Perfect"
        case .good:     return "Good"
        case .workable: return "Workable"
        case .hardCut:  return "Hard cut"
        }
    }

    var color: Color {
        switch self {
        case .perfect:  return Color(red: 0.15, green: 0.55, blue: 0.30)
        case .good:     return .blue
        case .workable: return .orange
        case .hardCut:  return Color.secondary
        }
    }
}

func blendGrade(anchor: MixTrack, candidate: MixTrack) -> BlendGrade {
    let bpmPct = anchor.bpm > 0
        ? abs(candidate.bpm - anchor.bpm) / anchor.bpm * 100.0
        : 100.0

    let isHarmonic: Bool
    if anchor.camelot.isEmpty || candidate.camelot.isEmpty {
        isHarmonic = false
    } else if anchor.camelot == candidate.camelot {
        isHarmonic = true
    } else {
        let compat = CamelotConverter.compatibleCodes(for: anchor.camelot)
        isHarmonic = compat.contains(candidate.camelot)
    }

    switch (isHarmonic, bpmPct) {
    case (true,  let p) where p <= 3: return .perfect
    case (true,  let p) where p <= 6: return .good
    case (true,  _):                  return .workable
    case (false, let p) where p <= 6: return .workable
    default:                          return .hardCut
    }
}

// MARK: - Transition info

struct TransitionInfo {
    let bpmDelta: String
    let label: String
    let group: HarmonicGroup?
}

func transitionInfo(fromCamelot: String, fromBPM: Double,
                    toCamelot: String,   toBPM: Double) -> TransitionInfo {
    let delta   = toBPM - fromBPM
    let rounded = Int(delta.rounded())
    let bpmDelta: String
    if abs(delta) < 0.5 {
        bpmDelta = "±0 BPM"
    } else {
        bpmDelta = "\(rounded >= 0 ? "+" : "")\(rounded) BPM"
    }
    guard !fromCamelot.isEmpty, !toCamelot.isEmpty else {
        return TransitionInfo(bpmDelta: bpmDelta, label: "—", group: nil)
    }
    if fromCamelot == toCamelot {
        return TransitionInfo(bpmDelta: bpmDelta, label: "\(fromCamelot)→\(toCamelot): perfect match", group: .perfectMatch)
    }
    let compat = CamelotConverter.compatibleCodes(for: fromCamelot)
    if compat.count >= 3 && toCamelot == compat[1] {
        return TransitionInfo(bpmDelta: bpmDelta, label: "\(fromCamelot)→\(toCamelot): energy boost",  group: .energyBoost)
    } else if compat.count >= 3 && toCamelot == compat[2] {
        return TransitionInfo(bpmDelta: bpmDelta, label: "\(fromCamelot)→\(toCamelot): energy drop",   group: .energyDrop)
    } else if !compat.isEmpty && toCamelot == compat[0] {
        return TransitionInfo(bpmDelta: bpmDelta, label: "\(fromCamelot)→\(toCamelot): mood switch",   group: .moodSwitch)
    } else {
        return TransitionInfo(bpmDelta: bpmDelta, label: "\(fromCamelot)→\(toCamelot): —",             group: nil)
    }
}

func transitionInfo(from: MixTrack, to: MixTrack) -> TransitionInfo {
    transitionInfo(fromCamelot: from.camelot, fromBPM: from.bpm,
                   toCamelot: to.camelot,     toBPM: to.bpm)
}

// MARK: - Transition bubble view

struct TransitionBubbleView: View {
    let anchor: MixTrack
    let candidate: MixTrack

    var body: some View {
        let grade  = blendGrade(anchor: anchor, candidate: candidate)
        let info   = transitionInfo(from: anchor, to: candidate)
        let bpmPct = anchor.bpm > 0
            ? abs(candidate.bpm - anchor.bpm) / anchor.bpm * 100.0
            : 0.0

        VStack(spacing: 3) {
            Circle()
                .fill(grade.color)
                .frame(width: 10, height: 10)
            Text(grade.label)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(grade.color)
                .multilineTextAlignment(.center)

            Rectangle()
                .fill(Color.secondary.opacity(0.2))
                .frame(height: 1)
                .padding(.vertical, 2)

            if !anchor.camelot.isEmpty, !candidate.camelot.isEmpty {
                Text("\(anchor.camelot)→\(candidate.camelot)")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(info.group?.color ?? Color.secondary)
            }
            Text(info.bpmDelta)
                .font(.system(size: 9, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
            Text(String(format: "%.1f%%", bpmPct))
                .font(.system(size: 8).monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .frame(width: 62)
        .padding(.horizontal, 6)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(grade.color.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(grade.color.opacity(0.3), lineWidth: 1)
                )
        )
    }
}
