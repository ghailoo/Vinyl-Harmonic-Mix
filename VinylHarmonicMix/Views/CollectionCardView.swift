import SwiftUI

struct CollectionCardView: View {
    let item: CollectionItem
    var hasMBID: Bool = false

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
    }

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
                if hasMBID { mbidBadge.padding(6) }
            }
        }
        .aspectRatio(1, contentMode: .fit)
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
