import SwiftUI

struct CollectionCardView: View {
    let item: CollectionItem
    var hasMBID: Bool = false
    var covered: Int = 0
    var total: Int = 0
    var localCovered: Int = 0
    var linkedCovered: Int = 0
    var isActive: Bool = false
    var isHighlighted: Bool = false

    @Environment(AudioPlaybackController.self) private var playback

    // Decoupled from render cycle — updated via .task after the card paints
    @State private var badgeCovered: Int = 0
    @State private var badgeTotal: Int = 0
    @State private var badgeLocalCovered: Int = 0
    @State private var badgeLinkedCovered: Int = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            coverImage
            Text(item.basicInformation.title)
                .font(.body.weight(.semibold))
                .lineLimit(2, reservesSpace: true)
            Text(item.basicInformation.artists.map(\.name).joined(separator: " & "))
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(String(item.basicInformation.year))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.accentColor, lineWidth: 2)
                .opacity(isHighlighted ? 1 : 0)
                .animation(.snappy, value: isHighlighted)
        )
        .task(id: covered &+ total &* 10_000 &+ localCovered &* 100_000 &+ linkedCovered &* 1_000_000_000) {
            badgeCovered       = covered
            badgeTotal         = total
            badgeLocalCovered  = localCovered
            badgeLinkedCovered = linkedCovered
        }
    }

    // MARK: - Cover image

    private var coverImage: some View {
        AsyncImage(url: URL(string: item.basicInformation.coverImage)) { phase in
            switch phase {
            case .success(let image):
                image.resizable()
                     .aspectRatio(contentMode: .fill)
            case .failure, .empty:
                ZStack {
                    Color.secondary.opacity(0.15)
                    Image(systemName: "music.note")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                }
            @unknown default:
                Color.secondary.opacity(0.15)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipped()
        .cornerRadius(8)
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 4) {
                if badgeLocalCovered > 0 {
                    Text("ES")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.statusComplete))
                        .help("\(badgeLocalCovered) of \(badgeTotal) tracks analyzed from local audio files")
                        .accessibilityLabel("\(badgeLocalCovered) of \(badgeTotal) tracks analyzed from local audio files")
                }
                if badgeCovered > 0 && badgeTotal > 0 {
                    Text("\(badgeCovered)/\(badgeTotal)")
                        .font(.system(.subheadline, design: .rounded, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(coverageColor))
                        .help("\(badgeCovered) of \(badgeTotal) tracks have BPM and key data")
                        .accessibilityLabel("\(badgeCovered) of \(badgeTotal) tracks have BPM and key data")
                }
                if badgeLinkedCovered > 0 { linkPip }
                if hasMBID { mbidBadge }
            }
            .padding(6)
        }
        .overlay(alignment: .bottomLeading) {
            if isActive {
                SpinningRecordView(
                    isPlaying: playback.isPlaying,
                    coverArtURL: URL(string: item.basicInformation.thumb),
                    diameter: 24
                )
                .padding(6)
                .shadow(color: .black.opacity(0.5), radius: 3, x: 0, y: 1)
            }
        }
    }

    private var coverageColor: Color {
        badgeCovered == badgeTotal
            ? Color.statusComplete
            : Color.statusPartial
    }

    private var linkPip: some View {
        Image(systemName: "link")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .padding(3)
            .background(Circle().fill(Color.accentColor.opacity(0.85)))
            .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
            .help("Local audio files linked to tracks")
            .accessibilityLabel("Local audio files linked to tracks")
    }

    private var mbidBadge: some View {
        Text("MBID")
            .font(.system(.subheadline, design: .rounded, weight: .bold))
            .tracking(0.3)
            .foregroundStyle(.white)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(
                LinearGradient(
                    colors: [
                        Color.badgeIdentified,
                        Color.badgeIdentifiedEnd
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .clipShape(Capsule(style: .continuous))
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(Color.white.opacity(0.6), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
            .help("Matched to MusicBrainz")
            .accessibilityLabel("Matched to MusicBrainz")
    }
}
