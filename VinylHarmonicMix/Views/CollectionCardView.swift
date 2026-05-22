import SwiftUI

struct CollectionCardView: View {
    let item: CollectionItem
    var hasMBID: Bool = false
    var covered: Int = 0
    var total: Int = 0
    var localCovered: Int = 0

    // Decoupled from render cycle — updated via .task after the card paints
    @State private var badgeCovered: Int = 0
    @State private var badgeTotal: Int = 0
    @State private var badgeLocalCovered: Int = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            coverImage
            Text(item.basicInformation.title)
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(2)
            Text(item.basicInformation.artists.map(\.name).joined(separator: " & "))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(String(item.basicInformation.year))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .task(id: covered &+ total &* 10_000 &+ localCovered &* 100_000) {
            badgeCovered      = covered
            badgeTotal        = total
            badgeLocalCovered = localCovered
        }
    }

    // MARK: - Cover image

    private var coverImage: some View {
        GeometryReader { geo in
            AsyncImage(url: URL(string: item.basicInformation.coverImage)) { phase in
                switch phase {
                case .success(let image):
                    image.resizable()
                         .aspectRatio(contentMode: .fill)
                case .failure, .empty:
                    ZStack {
                        Color.secondary.opacity(0.15)
                        Image(systemName: "music.note")
                            .font(.system(size: 28))
                            .foregroundStyle(.secondary)
                    }
                @unknown default:
                    Color.secondary.opacity(0.15)
                }
            }
            .frame(width: geo.size.width, height: geo.size.width)
            .clipped()
            .cornerRadius(8)
            .overlay(alignment: .topTrailing) {
                HStack(spacing: 4) {
                    if badgeLocalCovered > 0 {
                        Text("ES")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Color(red: 0.15, green: 0.55, blue: 0.30)))
                            .help("\(badgeLocalCovered) of \(badgeTotal) tracks analyzed from local audio files")
                    }
                    if badgeCovered > 0 && badgeTotal > 0 {
                        Text("\(badgeCovered)/\(badgeTotal)")
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(coverageColor))
                            .help("\(badgeCovered) of \(badgeTotal) tracks have BPM and key data")
                    }
                    if hasMBID { mbidBadge }
                }
                .padding(6)
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }

    private var coverageColor: Color {
        badgeCovered == badgeTotal
            ? Color(red: 0.20, green: 0.65, blue: 0.40)
            : Color(red: 0.95, green: 0.65, blue: 0.20)
    }

    private var mbidBadge: some View {
        Text("MBID")
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .tracking(0.3)
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                LinearGradient(
                    colors: [
                        Color(red: 0.35, green: 0.55, blue: 1.0),
                        Color(red: 0.55, green: 0.40, blue: 0.95)
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
    }
}
