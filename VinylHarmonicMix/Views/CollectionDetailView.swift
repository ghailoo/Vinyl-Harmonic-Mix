import SwiftUI
import SwiftData

struct CollectionDetailView: View {
    let item: CollectionItem
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.modelContext) private var modelContext
    @Environment(CollectionViewModel.self) private var viewModel

    @State private var detail: ReleaseDetail?
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var itemEntity: CollectionItemEntity?

    var body: some View {
        VStack(spacing: 0) {
            closeBar
            Divider()
            contentBody
        }
        .frame(minWidth: 560, idealWidth: 640, minHeight: 600, idealHeight: 720)
        .task(id: item.id) {
            await load()
            loadEntity()
        }
    }

    // MARK: - Top bar

    private var closeBar: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: - Content states

    @ViewBuilder
    private var contentBody: some View {
        if isLoading {
            VStack(spacing: 10) {
                ProgressView()
                Text("Loading release details…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = loadError {
            VStack(spacing: 16) {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                Button("Retry") {
                    Task { await load() }
                }
                .buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let detail {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    headerSection(detail: detail)
                    tagSection
                    tracklistSection(detail: detail)
                    if let extraartists = detail.extraartists, !extraartists.isEmpty {
                        creditsSection(extraartists: extraartists)
                    }
                    if let notes = detail.notes, !notes.isEmpty {
                        notesSection(notes: notes)
                    }
                    if let identifiers = detail.identifiers, !identifiers.isEmpty {
                        identifiersSection(identifiers: identifiers)
                    }
                    mbidSection
                    discogsLinkSection
                }
                .padding(.bottom, 24)
            }
        } else {
            Color.clear
        }
    }

    // MARK: - Header

    private func headerSection(detail: ReleaseDetail) -> some View {
        HStack(alignment: .top, spacing: 20) {
            coverImage
            infoStack(detail: detail)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 16)
    }

    private var coverURL: URL? {
        if !item.basicInformation.coverImage.isEmpty,
           let url = URL(string: item.basicInformation.coverImage) { return url }
        if !item.basicInformation.thumb.isEmpty,
           let url = URL(string: item.basicInformation.thumb) { return url }
        return nil
    }

    private var coverImage: some View {
        AsyncImage(url: coverURL) { phase in
            switch phase {
            case .success(let img):
                img.resizable().scaledToFill()
            default:
                Rectangle()
                    .fill(.secondary.opacity(0.15))
                    .overlay(Image(systemName: "music.note").foregroundStyle(.tertiary))
            }
        }
        .frame(width: 240, height: 240)
        .cornerRadius(8)
        .clipped()
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.primary.opacity(0.1), lineWidth: 1)
        )
    }

    private func infoStack(detail: ReleaseDetail) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(item.basicInformation.title)
                .font(.system(size: 24, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)

            let artistLine = item.basicInformation.artists.map(\.name).joined(separator: " & ")
            if !artistLine.isEmpty {
                Text(artistLine)
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
            }

            let yearCountry: String = {
                let y = item.basicInformation.year > 0 ? String(item.basicInformation.year) : nil
                return [y, detail.country].compactMap { $0 }.joined(separator: " · ")
            }()
            if !yearCountry.isEmpty {
                Text(yearCountry)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }

            // FIX 3 — "Released:" line if present and different from bare year
            if let released = detail.released,
               !released.isEmpty,
               released != String(item.basicInformation.year) {
                Text("Released: \(released)")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }

            starRow

            if let fmt = item.basicInformation.formats.first {
                formatBadge(fmt)
            }

            // FIX 2 — deduplicated label rows
            let allLabels = detail.labels ?? item.basicInformation.labels
            ForEach(groupedLabels(from: allLabels), id: \.name) { group in
                let catnos = group.catnos.isEmpty
                    ? ""
                    : " · " + group.catnos.joined(separator: ", ")
                Text("\(group.name)\(catnos)")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // FIX 2 — group by label name, deduplicate catalog numbers
    private func groupedLabels(from labels: [LabelCredit]) -> [(name: String, catnos: [String])] {
        let grouped = Dictionary(grouping: labels, by: { $0.name })
        return grouped.map { name, entries in
            let catnos = Array(Set(entries.map(\.catno).filter { !$0.isEmpty })).sorted()
            return (name: name, catnos: catnos)
        }.sorted { $0.name < $1.name }
    }

    private var starRow: some View {
        HStack(spacing: 3) {
            ForEach(1...5, id: \.self) { star in
                Image(systemName: item.rating > 0 && star <= item.rating ? "star.fill" : "star")
                    .font(.system(size: 14))
                    .foregroundStyle(
                        item.rating > 0 && star <= item.rating ? Color.accentColor : Color.secondary
                    )
            }
            if item.rating == 0 {
                Text("Not rated")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func formatBadge(_ fmt: Format) -> some View {
        let parts = ([fmt.name] + (fmt.descriptions ?? [])).joined(separator: " · ")
        return Text(parts)
            .font(.system(size: 12))
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.accentColor.opacity(0.15))
            .cornerRadius(4)
    }

    // MARK: - Tags

    @ViewBuilder
    private var tagSection: some View {
        let tags = item.basicInformation.genres + item.basicInformation.styles
        if !tags.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(tags, id: \.self) { tag in
                        Text(tag)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.secondary.opacity(0.15))
                            .cornerRadius(4)
                    }
                }
                .padding(.horizontal, 20)
            }
            .padding(.bottom, 16)
        }
    }

    // MARK: - Tracklist

    private func tracklistSection(detail: ReleaseDetail) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Tracklist")
                    .font(.system(size: 16, weight: .semibold))
                Divider()
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 4)

            ForEach(Array(detail.tracklist.enumerated()), id: \.offset) { _, track in
                HStack(spacing: 0) {
                    Text(track.position)
                        .font(.system(size: 13).monospaced())
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .leading)
                    Text(track.title)
                        .font(.system(size: 14))
                        .lineLimit(2)
                    Spacer()
                    Text(track.duration.isEmpty ? "—" : track.duration)
                        .font(.system(size: 13).monospaced())
                        .foregroundStyle(.secondary)
                        .frame(width: 50, alignment: .trailing)
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 20)
            }
        }
    }

    // MARK: - FIX 3: Credits

    private func creditsSection(extraartists: [Credit]) -> some View {
        let grouped: [(role: String, names: String)] = {
            let filtered = extraartists.filter { !$0.role.isEmpty }
            let dict = Dictionary(grouping: filtered) { $0.role.lowercased() }
            return dict
                .map { _, credits in (role: credits[0].role, names: credits.map(\.name).joined(separator: ", ")) }
                .sorted { $0.role.lowercased() < $1.role.lowercased() }
        }()

        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Credits")
                    .font(.system(size: 16, weight: .semibold))
                Divider()
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 4)

            ForEach(grouped, id: \.role) { entry in
                HStack(alignment: .top, spacing: 0) {
                    Text(entry.role)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .frame(width: 120, alignment: .leading)
                    Text(entry.names)
                        .font(.system(size: 13))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 20)
            }
        }
    }

    // MARK: - Notes

    private func notesSection(notes: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Notes")
                .font(.system(size: 16, weight: .semibold))
            Divider()
            Text(notes)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
    }

    // MARK: - FIX 3: Identifiers

    private func identifiersSection(identifiers: [Identifier]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Identifiers")
                    .font(.system(size: 16, weight: .semibold))
                Divider()
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 4)

            ForEach(identifiers, id: \.self) { identifier in
                HStack(alignment: .top, spacing: 0) {
                    Text(identifier.type)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .frame(width: 120, alignment: .leading)
                    Text(identifier.value)
                        .font(.system(size: 13))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 20)
            }
        }
    }

    // MARK: - Discogs link

    private var discogsLinkSection: some View {
        HStack {
            Button {
                if let url = URL(string: "https://www.discogs.com/release/\(item.releaseId)") {
                    openURL(url)
                }
            } label: {
                Label("View on Discogs", systemImage: "arrow.up.right.square")
            }
            .buttonStyle(.bordered)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
    }

    // MARK: - MBID section

    @ViewBuilder
    private var mbidSection: some View {
        if let entity = itemEntity {
            mbidStatusRow(entity: entity)
        }
    }

    private func mbidStatusRow(entity: CollectionItemEntity) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("MusicBrainz")
                    .font(.system(size: 16, weight: .semibold))
                Divider()
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 8)

            switch entity.scanState {
            case .matched:
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.system(size: 13))
                        Text(entity.mbidMatchedTitle ?? "Matched")
                            .font(.system(size: 13))
                        if let matchedTitle = entity.mbidMatchedTitle,
                           matchedTitle.lowercased() != item.basicInformation.title.lowercased() {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .font(.system(size: 12))
                                .help("Title mismatch — Discogs: \(item.basicInformation.title) · MusicBrainz: \(matchedTitle)")
                        }
                    }
                    if let artist = entity.mbidMatchedArtist, !artist.isEmpty {
                        Text(artist)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    if let mbid = entity.mbid {
                        Button {
                            if let url = URL(string: "https://musicbrainz.org/release/\(mbid)") {
                                openURL(url)
                            }
                        } label: {
                            Label("View on MusicBrainz", systemImage: "arrow.up.right.square")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .padding(.top, 4)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 12)

            case .notFound:
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "questionmark.circle")
                            .foregroundStyle(.secondary)
                            .font(.system(size: 13))
                        Text("No MusicBrainz match found")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                    Button {
                        let query = [item.basicInformation.artists.first?.name, item.basicInformation.title]
                            .compactMap { $0 }
                            .joined(separator: " ")
                            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
                        if let url = URL(string: "https://musicbrainz.org/search?query=\(query)&type=release") {
                            openURL(url)
                        }
                    } label: {
                        Label("Search manually on MusicBrainz", systemImage: "magnifyingglass")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .padding(.top, 4)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 12)

            case .failed:
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .font(.system(size: 13))
                    Text("Scan failed — will retry on next scan")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 12)

            case .matchedViaSearch:
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.system(size: 13))
                        Text(entity.mbidMatchedTitle ?? "Matched")
                            .font(.system(size: 13))
                        Text("via search")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.1))
                            .cornerRadius(3)
                        if let matchedTitle = entity.mbidMatchedTitle,
                           matchedTitle.lowercased() != item.basicInformation.title.lowercased() {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .font(.system(size: 12))
                                .help("Title mismatch — Discogs: \(item.basicInformation.title) · MusicBrainz: \(matchedTitle)")
                        }
                    }
                    if let artist = entity.mbidMatchedArtist, !artist.isEmpty {
                        Text(artist)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    if let mbid = entity.mbid {
                        Button {
                            if let url = URL(string: "https://musicbrainz.org/release/\(mbid)") {
                                openURL(url)
                            }
                        } label: {
                            Label("View on MusicBrainz", systemImage: "arrow.up.right.square")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Matched via indexed search — verify the release matches your pressing.")
                        .padding(.top, 4)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 12)

            case .unscanned:
                HStack(spacing: 6) {
                    Image(systemName: "clock")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 13))
                    Text("Not yet scanned")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
            }
        }
    }

    private func loadEntity() {
        let instanceId = item.id
        var descriptor = FetchDescriptor<CollectionItemEntity>(
            predicate: #Predicate { $0.instanceId == instanceId }
        )
        descriptor.fetchLimit = 1
        itemEntity = try? modelContext.fetch(descriptor).first
    }

    // MARK: - Data loading

    private func load() async {
        isLoading = true
        loadError = nil
        detail = nil
        defer { isLoading = false }
        do {
            detail = try await viewModel.loadDetail(for: item)
        } catch {
            loadError = error.localizedDescription
        }
    }
}
