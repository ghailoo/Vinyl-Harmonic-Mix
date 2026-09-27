import SwiftUI

// MARK: - Harmonic strip tile

struct StripTileView: View {
    let track: MixTrack
    let group: HarmonicGroup
    let thumbURL: URL?
    let releaseName: String?
    let isCandidate: Bool

    private var badgeLabel: String {
        switch group {
        case .perfectMatch: return "EXACT"
        case .energyBoost:  return "ENERGY+"
        case .energyDrop:   return "ENERGY−"
        case .moodSwitch:   return "MOOD"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                AsyncImage(url: thumbURL) { phase in
                    switch phase {
                    case .success(let img):
                        img.resizable().aspectRatio(contentMode: .fill)
                    default:
                        ZStack {
                            Color.secondary.opacity(0.12)
                            Image(systemName: "music.note").font(.largeTitle).foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(width: 176, height: 176)
                .clipped()

                Circle()
                    .fill(group.color)
                    .frame(width: 14, height: 14)
                    .overlay(Circle().strokeBorder(.white.opacity(0.7), lineWidth: 1))
                    .padding(6)
            }
            .frame(width: 176, height: 176)

            VStack(alignment: .leading, spacing: 3) {
                Text(track.displayTitle)
                    .font(.callout.weight(.semibold)).lineLimit(1)
                Text(track.displayArtist)
                    .font(.callout).foregroundStyle(.secondary).lineLimit(1)
                if let release = releaseName {
                    Text("from \(release)")
                        .font(.callout).foregroundStyle(.tertiary).lineLimit(1)
                }
                HStack(spacing: 4) {
                    badge("\(Int(track.bpm.rounded()))", bg: Color.statusComplete)
                    badge(track.camelot, bg: Color.statusComplete)
                    badge(badgeLabel, bg: group.color.opacity(0.2), fg: group.color)
                }
            }
            .padding(8)
        }
        .frame(width: 176)
        .background(RoundedRectangle(cornerRadius: 10)
            .fill(isCandidate ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(isCandidate ? Color.accentColor.opacity(0.55) : Color.clear, lineWidth: 1.5))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private func badge(_ text: String, bg: Color, fg: Color = .white) -> some View {
        Text(text)
            .font(.subheadline.weight(.bold).monospacedDigit())
            .foregroundStyle(fg)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(Capsule().fill(bg))
    }
}
