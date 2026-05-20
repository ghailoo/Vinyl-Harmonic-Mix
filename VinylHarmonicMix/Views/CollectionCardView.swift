import SwiftUI

struct CollectionCardView: View {
    let item: CollectionItem

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
        }
        .aspectRatio(1, contentMode: .fit)
    }
}
