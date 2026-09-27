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
        case .perfectMatch: return .statusCompleteForeground
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
        case .perfect:  return .statusCompleteForeground
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

        VStack(spacing: 0) {
            // Hero: BPM% — the first thing the eye hits
            Text(String(format: "%.1f%%", bpmPct))
                .font(.title.weight(.black).monospacedDigit())
                .foregroundStyle(grade.color)
                .padding(.bottom, 2)

            Text(info.bpmDelta)
                .font(.callout.weight(.medium).monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.bottom, 10)

            // Camelot key transition
            if !anchor.camelot.isEmpty, !candidate.camelot.isEmpty {
                Text("\(anchor.camelot) → \(candidate.camelot)")
                    .font(.body.weight(.bold).monospacedDigit())
                    .foregroundStyle(.primary)
                    .padding(.bottom, 10)
            }

            Rectangle()
                .fill(grade.color.opacity(0.25))
                .frame(height: 0.5)
                .padding(.bottom, 8)

            // Group label
            if let group = info.group {
                Text(group.rawValue)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(grade.color.opacity(0.9))
                    .multilineTextAlignment(.center)
                    .padding(.bottom, 7)
            }

            // Grade pips + label
            gradeRow(grade: grade)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 14)
        .frame(width: 96)
        .background {
            let shape = RoundedRectangle(cornerRadius: 14)
            ZStack {
                // Gradient fill — stronger at top, fades down
                shape.fill(LinearGradient(
                    colors: [grade.color.opacity(0.20), grade.color.opacity(0.04)],
                    startPoint: .top, endPoint: .bottom
                ))
                // Glass highlight at top edge
                shape.fill(LinearGradient(
                    colors: [Color.white.opacity(0.10), Color.clear],
                    startPoint: .top,
                    endPoint: .init(x: 0.5, y: 0.45)
                ))
                // Gradient stroke — vivid at top, soft at bottom
                shape.strokeBorder(LinearGradient(
                    colors: [grade.color.opacity(0.60), grade.color.opacity(0.18)],
                    startPoint: .top, endPoint: .bottom
                ), lineWidth: 1.5)
            }
        }
        .shadow(color: grade.color.opacity(0.28), radius: 10, x: 0, y: 4)
    }

    @ViewBuilder
    private func gradeRow(grade: BlendGrade) -> some View {
        let filled: Int = {
            switch grade {
            case .perfect:  return 3
            case .good:     return 2
            case .workable: return 1
            case .hardCut:  return 0
            }
        }()
        HStack(spacing: 4) {
            HStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { i in
                    if i < filled {
                        Circle()
                            .fill(grade.color)
                            .frame(width: 7, height: 7)
                            .shadow(color: grade.color.opacity(0.65), radius: 3)
                    } else {
                        Circle()
                            .strokeBorder(grade.color.opacity(0.28), lineWidth: 1)
                            .frame(width: 7, height: 7)
                    }
                }
            }
            Text(grade.label)
                .font(.callout.weight(.semibold))
                .foregroundStyle(grade.color.opacity(0.7))
        }
    }
}
