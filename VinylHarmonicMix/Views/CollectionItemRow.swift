import SwiftUI

struct CollectionItemRow: View {
    let item: CollectionItem

    var body: some View {
        HStack(spacing: 10) {
            AsyncImage(url: URL(string: item.basicInformation.thumb)) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().aspectRatio(contentMode: .fill)
                case .failure:
                    Image(systemName: "photo").foregroundStyle(.tertiary)
                default:
                    Rectangle().fill(.secondary.opacity(0.1))
                }
            }
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 4))

            VStack(alignment: .leading, spacing: 2) {
                Text(item.basicInformation.title)
                    .lineLimit(1)
                Text(item.basicInformation.artists.map(\.name).joined(separator: " & "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(String(item.basicInformation.year))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }
}
