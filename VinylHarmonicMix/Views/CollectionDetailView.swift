import SwiftUI
import SwiftData
#if os(macOS)
import AppKit
#endif

struct CollectionDetailView: View {
    let item: CollectionItem
    var onPromoteToCurrent: ((MixTrack) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.modelContext) private var modelContext
    @Environment(CollectionViewModel.self) private var viewModel
    @Environment(AudioPlaybackController.self) private var playback
    @Environment(MBIDScanCoordinator.self) private var scanCoordinator
    @Environment(RecordingsScanCoordinator.self) private var recordingsCoordinator
    @Environment(AudioFeaturesScanCoordinator.self) private var audioFeaturesCoordinator
    @Environment(FileMatchCoordinator.self) private var fileMatchCoordinator
    @Environment(LocalAnalysisCoordinator.self) private var localAnalysisCoordinator

    @State private var detail: ReleaseDetail?
    @State private var isLoading = false
    @State private var galleryURLs: [String] = []
    @State private var galleryIndex: Int = 0
    @State private var loadError: String?
    @State private var itemEntity: CollectionItemEntity?
    @State private var trackEntities: [TrackEntity] = []
    @State private var featureEntities: [RecordingFeaturesEntity] = []
    @State private var mbidCopied = false
    @State private var copiedRecordingMBID: String? = nil
    // Release-level manual MBID entry (notFound path)
    @State private var manualReleaseMBID: String = ""
    @State private var manualReleaseMBIDError: String? = nil
    // Per-track recording MBID editing
    @State private var editingTrackMBID: String? = nil
    @State private var recordingMBIDInput: String = ""
    @State private var recordingMBIDInputError: String? = nil
    // Status for view-initiated single-item enrichment (fetch-recordings button, per-track)
    @State private var singleEnrichStatus: String? = nil
    // Path of the file currently being Essentia-analyzed after manual assignment; nil = none
    @State private var analyzingTrackPath: String? = nil
    @State private var prefetchedPaths: [String] = []
    @State private var showUnlinkConfirmation = false

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
            loadTrackEntities()
            loadFeatureEntities()
            prefetchWaveforms()
        }
        .onDisappear { playback.cancelWaveformLoads(filePaths: prefetchedPaths) }
        .onChange(of: scanCoordinator.enrichmentStatus) { _, newStatus in
            if newStatus == nil {
                loadTrackEntities()
                loadFeatureEntities()
            }
        }
    }

    // MARK: - Top bar

    private var closeBar: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .help("Close")
            .accessibilityLabel("Close")
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
                    mbidSection
                    if let extraartists = detail.extraartists, !extraartists.isEmpty {
                        creditsSection(extraartists: extraartists)
                    }
                    if let notes = detail.notes, !notes.isEmpty {
                        notesSection(notes: notes)
                    }
                    if let identifiers = detail.identifiers, !identifiers.isEmpty {
                        identifiersSection(identifiers: identifiers)
                    }
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

    private var currentGalleryURL: URL? {
        guard !galleryURLs.isEmpty else {
            // Fallback before gallery loads
            if !item.basicInformation.coverImage.isEmpty { return URL(string: item.basicInformation.coverImage) }
            if !item.basicInformation.thumb.isEmpty { return URL(string: item.basicInformation.thumb) }
            return nil
        }
        return URL(string: galleryURLs[galleryIndex])
    }

    private var coverImage: some View {
        ZStack(alignment: .center) {
            AsyncImage(url: currentGalleryURL) { phase in
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
            .clipShape(RoundedRectangle(cornerRadius: 8))

            if galleryURLs.count > 1 {
                HStack {
                    Button {
                        galleryIndex = galleryIndex > 0 ? galleryIndex - 1 : galleryURLs.count - 1
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(8)
                            .background(Circle().fill(.black.opacity(0.5)))
                    }
                    .buttonStyle(.plain)
                    .help("Previous photo")
                    .accessibilityLabel("Previous photo")

                    Spacer()

                    Button {
                        galleryIndex = galleryIndex < galleryURLs.count - 1 ? galleryIndex + 1 : 0
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(8)
                            .background(Circle().fill(.black.opacity(0.5)))
                    }
                    .buttonStyle(.plain)
                    .help("Next photo")
                    .accessibilityLabel("Next photo")
                }
                .padding(.horizontal, 8)
                .frame(width: 240, height: 240)

                VStack {
                    Spacer()
                    Text("\(galleryIndex + 1) / \(galleryURLs.count)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(.black.opacity(0.5)))
                        .padding(.bottom, 8)
                }
                .frame(width: 240, height: 240)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.1), lineWidth: 1))
    }

    private func infoStack(detail: ReleaseDetail) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(item.basicInformation.title)
                .font(.largeTitle.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)

            let artistLine = item.basicInformation.artists.map(\.name).joined(separator: " & ")
            if !artistLine.isEmpty {
                Text(artistLine)
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            let yearCountry: String = {
                let y = item.basicInformation.year > 0 ? String(item.basicInformation.year) : nil
                return [y, detail.country].compactMap { $0 }.joined(separator: " · ")
            }()
            if !yearCountry.isEmpty {
                Text(yearCountry)
                    .font(.body)
                    .foregroundStyle(.secondary)
            }

            // FIX 3 — "Released:" line if present and different from bare year
            if let released = detail.released,
               !released.isEmpty,
               released != String(item.basicInformation.year) {
                Text("Released: \(released)")
                    .font(.body)
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
                    .font(.body)
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
                    .font(.body)
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
            .font(.callout)
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
                            .font(.callout)
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
                    .font(.title3.weight(.semibold))
                Divider()
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 4)

            if trackEntities.isEmpty, detail.tracklist.contains(where: { !$0.position.isEmpty }) {
                HStack(spacing: 8) {
                    Text("Tracks not created yet")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Create tracks from tracklist") {
                        guard let e = itemEntity else { return }
                        _ = recordingsCoordinator.synthesizeTracksForOrphanRelease(e)
                        try? modelContext.save()
                        loadTrackEntities()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
            }

            ForEach(Array(detail.tracklist.enumerated()), id: \.offset) { index, track in
                let rmbid = recordingMBID(forPosition: track.position, fallbackIndex: index)
                let matchedTrack = rmbid.flatMap { r in trackEntities.first { $0.recordingMBID == r } }
                let normPos = normalizePosition(track.position)
                let trackEntityByPos: TrackEntity? =
                    trackEntities.first { normalizePosition($0.position) == normPos }
                    ?? matchedTrack
                let filePath: String? = {
                    let candidate = matchedTrack ?? trackEntityByPos
                    guard let t = candidate, t.fileMatchState == "confident" else { return nil }
                    return t.primaryLocalFilePath
                }()
                let isActive  = filePath.map { playback.currentFilePath == $0 } ?? false
                let isPlaying = isActive && playback.isPlaying

                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 0) {
                        Text(track.position)
                            .font(.body.monospaced())
                            .foregroundStyle(.secondary)
                            .frame(width: 40, alignment: .leading)
                        Text(track.title)
                            .font(.body)
                            .lineLimit(2)
                        Spacer()
                        if let te = trackEntityByPos {
                            Button {
                                editingTrackMBID = te.trackMBID
                                recordingMBIDInput = te.recordingMBID
                                recordingMBIDInputError = nil
                            } label: {
                                Image(systemName: "waveform.badge.magnifyingglass")
                                    .font(.body)
                                    .foregroundStyle(.quaternary)
                            }
                            .buttonStyle(.plain)
                            .help("Set or correct the recording MBID for this track")
                            .accessibilityLabel("Set or correct the recording MBID for this track")
                            .padding(.trailing, 4)
                        }
                        if let fp = filePath {
                            Button {
                                playback.play(filePath: fp)
                            } label: {
                                Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                                    .font(.title3)
                                    .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
                                    .contentTransition(.symbolEffect(.replace))
                            }
                            .buttonStyle(.plain)
                            .help(isPlaying ? "Pause" : "Play")
                            .accessibilityLabel(isPlaying ? "Pause" : "Play")
                            .padding(.trailing, 6)
                        }
                        if onPromoteToCurrent != nil,
                           let te = trackEntityByPos,
                           te.effectiveBpm != nil,
                           te.effectiveCamelot != nil {
                            Button {
                                guard let te = trackEntityByPos,
                                      let bpm = te.effectiveBpm,
                                      let camelot = te.effectiveCamelot,
                                      let fp = te.primaryLocalFilePath else { return }
                                let mix = MixTrack(
                                    displayArtist: te.artistCredit,
                                    displayTitle:  te.title,
                                    bpm:           bpm,
                                    camelot:       camelot,
                                    key:           te.effectiveKey ?? "",
                                    source:        te.featureSource,
                                    filePath:      fp,
                                    label:         item.basicInformation.labels.first?.name ?? "",
                                    year:          item.basicInformation.year
                                )
                                onPromoteToCurrent?(mix)
                                dismiss()
                            } label: {
                                Image(systemName: "plus.circle.fill")
                                    .font(.title3)
                                    .foregroundStyle(Color(red: 0.15, green: 0.55, blue: 0.30))
                            }
                            .buttonStyle(.plain)
                            .help("Set as Current Track in Set Builder")
                            .accessibilityLabel("Set as Current Track in Set Builder")
                            .padding(.trailing, 6)
                        }
                        Text(track.duration.isEmpty ? "—" : track.duration)
                            .font(.body.monospaced())
                            .foregroundStyle(.secondary)
                            .frame(width: 50, alignment: .trailing)
                    }
                    .padding(.top, 6)
                    .padding(.bottom, (rmbid != nil || trackEntityByPos?.effectiveBpm != nil) ? 3 : 6)
                    .padding(.horizontal, 20)

                    if let rmbid {
                        recordingMBIDCaption(rmbid)
                            .padding(.bottom, isActive ? 4 : 6)
                            .padding(.horizontal, 20)
                            .padding(.leading, 40)
                    } else if let te = trackEntityByPos, te.effectiveBpm != nil {
                        orphanFeatureRow(trackEntity: te)
                            .padding(.bottom, isActive ? 4 : 6)
                            .padding(.horizontal, 20)
                            .padding(.leading, 40)
                    }

                    if isActive, let fp = filePath {
                        trackPlayerArea(filePath: fp)
                            .padding(.top, 2)
                            .padding(.bottom, 8)
                            .padding(.horizontal, 20)
                            .padding(.leading, 40)
                    }

                    if let te = trackEntityByPos, editingTrackMBID == te.trackMBID {
                        perTrackMBIDEditField(trackEntity: te)
                            .padding(.bottom, 6)
                            .padding(.horizontal, 20)
                            .padding(.leading, 40)
                    }

                    if let te = trackEntityByPos {
                        perTrackFileLinkRow(trackEntity: te)
                            .padding(.bottom, 6)
                            .padding(.horizontal, 20)
                            .padding(.leading, 40)
                    }
                }
            }

            if let status = singleEnrichStatus {
                Label(status, systemImage: "arrow.clockwise")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 20)
                    .padding(.top, 4)
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
                    .font(.title3.weight(.semibold))
                Divider()
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 4)

            ForEach(grouped, id: \.role) { entry in
                HStack(alignment: .top, spacing: 0) {
                    Text(entry.role)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .frame(width: 120, alignment: .leading)
                    Text(entry.names)
                        .font(.body)
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
                .font(.title3.weight(.semibold))
            Divider()
            Text(notes)
                .font(.body)
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
                    .font(.title3.weight(.semibold))
                Divider()
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 4)

            ForEach(identifiers, id: \.self) { identifier in
                HStack(alignment: .top, spacing: 0) {
                    Text(identifier.type)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .frame(width: 120, alignment: .leading)
                    Text(identifier.value)
                        .font(.body)
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

    @ViewBuilder
    private func mbidStatusRow(entity: CollectionItemEntity) -> some View {
        switch entity.scanState {
        case .matched, .matchedViaSearch, .matchedManually:
            VStack(alignment: .leading, spacing: 0) {
                mbidSectionHeader
                VStack(alignment: .leading, spacing: 8) {
                    if let title = entity.mbidMatchedTitle {
                        Text("Release: \(title) — \(entity.mbidMatchedArtist ?? "—")")
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 8) {
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
                            Button {
                                copyMBID(mbid)
                            } label: {
                                Text(mbidCopied ? "✓ Copied" : "Copy MBID")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            Button(role: .destructive) {
                                showUnlinkConfirmation = true
                            } label: {
                                Label("Unlink", systemImage: "link")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .help("Remove this MusicBrainz match and clear track recordings")
                            .accessibilityLabel("Remove this MusicBrainz match and clear track recordings")
                        }
                    }
                    if entity.scanState == .matchedViaSearch {
                        Text("Matched via search")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .help("This match was found via indexed search rather than a direct Discogs↔MusicBrainz URL relationship. Verify it matches your pressing.")
                            .accessibilityLabel("This match was found via indexed search rather than a direct Discogs↔MusicBrainz URL relationship. Verify it matches your pressing.")
                    } else if entity.scanState == .matchedManually {
                        Text("Set manually")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }

                    if trackEntities.isEmpty {
                        Divider()
                        HStack(spacing: 8) {
                            Text("No tracks fetched yet")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button("Fetch recordings & audio features") {
                                guard let e = itemEntity, e.mbid != nil else { return }
                                singleEnrichStatus = "Fetching tracks…"
                                Task {
                                    await recordingsCoordinator.startForSingle(e)
                                    loadTrackEntities()
                                    singleEnrichStatus = "Fetching audio features…"
                                    await audioFeaturesCoordinator.startForSingle(e)
                                    loadFeatureEntities()
                                    singleEnrichStatus = nil
                                }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }

                    if let status = scanCoordinator.enrichmentStatus ?? singleEnrichStatus {
                        Label(status, systemImage: "arrow.clockwise")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
            }
            .alert("Unlink MusicBrainz match?", isPresented: $showUnlinkConfirmation) {
                Button("Cancel", role: .cancel) { }
                Button("Unlink", role: .destructive) {
                    if let entity = itemEntity { unlinkMBID(entity: entity) }
                }
            } message: {
                Text("This will remove the MusicBrainz match for this release and delete all per-track recording MBIDs. You can re-match the release afterward.")
            }

        case .notFound:
            VStack(alignment: .leading, spacing: 0) {
                mbidSectionHeader
                VStack(alignment: .leading, spacing: 8) {
                    Text("No MusicBrainz match")
                        .font(.body)
                        .foregroundStyle(.secondary)
                    Button {
                        let artist = item.basicInformation.artists.map(\.name).joined(separator: " ")
                        let encodedQuery = "\(item.basicInformation.title) \(artist)"
                            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
                        if let url = URL(string: "https://musicbrainz.org/search?type=release&query=\(encodedQuery)") {
                            openURL(url)
                        }
                    } label: {
                        Label("Search manually", systemImage: "arrow.up.right.square")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Divider()
                    Text("Paste a release MBID to import tracks & audio features:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        TextField("e.g. 550e8400-e29b-41d4-a716-446655440000", text: $manualReleaseMBID)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.caption, design: .monospaced))
                            .onChange(of: manualReleaseMBID) { _, newValue in
                                let normalized = normalizeMBIDInput(newValue)
                                if normalized != newValue { manualReleaseMBID = normalized }
                            }
                        Button("Fetch") {
                            let trimmed = manualReleaseMBID.trimmingCharacters(in: .whitespaces)
                            guard isValidMBID(trimmed) else {
                                manualReleaseMBIDError = "Not a valid MBID (8-4-4-4-12 hex characters)"
                                return
                            }
                            manualReleaseMBIDError = nil
                            manualReleaseMBID = ""
                            scanCoordinator.setMBIDManuallyAndEnrich(
                                instanceId: item.id,
                                mbid: trimmed,
                                recordingsCoordinator: recordingsCoordinator,
                                audioFeaturesCoordinator: audioFeaturesCoordinator
                            )
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(!isValidMBID(manualReleaseMBID.trimmingCharacters(in: .whitespaces)))
                    }
                    if let err = manualReleaseMBIDError {
                        Text(err).font(.caption2).foregroundStyle(.red)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
            }

        case .failed:
            VStack(alignment: .leading, spacing: 0) {
                mbidSectionHeader
                VStack(alignment: .leading, spacing: 4) {
                    Text("MBID lookup failed")
                        .font(.body)
                        .foregroundStyle(.secondary)
                    Text("Retry next scan")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
            }

        case .needsReview:
            VStack(alignment: .leading, spacing: 0) {
                mbidSectionHeader
                VStack(alignment: .leading, spacing: 4) {
                    Text("Needs review")
                        .font(.body)
                        .foregroundStyle(.secondary)
                    Text("Multiple possible MusicBrainz matches — review them in the MBID scan panel")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
            }

        case .unscanned:
            EmptyView()
        }
    }

    private var mbidSectionHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("MusicBrainz")
                .font(.title3.weight(.semibold))
            Divider()
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 8)
    }

    private func copyMBID(_ mbid: String) {
#if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(mbid, forType: .string)
#else
        UIPasteboard.general.string = mbid
#endif
        mbidCopied = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            mbidCopied = false
        }
    }

    // MARK: - Per-track recording MBID edit

    @ViewBuilder
    private func perTrackMBIDEditField(trackEntity: TrackEntity) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                TextField("Recording MBID (UUID format)", text: $recordingMBIDInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: 260)
                Button("Set") {
                    let trimmed = recordingMBIDInput.trimmingCharacters(in: .whitespaces)
                    guard isValidMBID(trimmed) else {
                        recordingMBIDInputError = "Not a valid MBID (8-4-4-4-12 hex)"
                        return
                    }
                    recordingMBIDInputError = nil
                    trackEntity.recordingMBID = trimmed
                    try? modelContext.save()
                    editingTrackMBID = nil
                    recordingMBIDInput = ""
                    guard let entity = itemEntity else { return }
                    singleEnrichStatus = "Fetching audio features…"
                    Task {
                        await audioFeaturesCoordinator.startForSingle(entity)
                        loadFeatureEntities()
                        singleEnrichStatus = nil
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(recordingMBIDInput.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Cancel") {
                    editingTrackMBID = nil
                    recordingMBIDInput = ""
                    recordingMBIDInputError = nil
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            if let err = recordingMBIDInputError {
                Text(err).font(.caption2).foregroundStyle(.red)
            }
        }
    }

    private func isValidMBID(_ s: String) -> Bool {
        let pattern = "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"
        return s.range(of: pattern, options: .regularExpression) != nil
    }

    private func normalizeMBIDInput(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if isValidMBID(trimmed) { return trimmed }
        if let url = URL(string: trimmed), let last = url.pathComponents.last {
            let candidate = last.trimmingCharacters(in: .whitespacesAndNewlines)
            if isValidMBID(candidate) { return candidate }
        }
        let pattern = #"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"#
        if let range = trimmed.range(of: pattern, options: .regularExpression) {
            return String(trimmed[range])
        }
        return trimmed
    }

    // MARK: - Per-track file link

    @ViewBuilder
    private func perTrackFileLinkRow(trackEntity: TrackEntity) -> some View {
        if trackEntity.fileMatchState == "confident",
           let linkedPath = trackEntity.primaryLocalFilePath {
            HStack(spacing: 6) {
                Image(systemName: "link")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(URL(fileURLWithPath: linkedPath).lastPathComponent)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 200, alignment: .leading)
                if analyzingTrackPath == linkedPath {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.7)
                    Text("Analyzing…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    Button("Change") {
                        pickFileForTrack(trackEntity: trackEntity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    Button("Unlink") {
                        fileMatchCoordinator.unlinkMatch(trackMBID: trackEntity.trackMBID)
                        loadTrackEntities()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .foregroundStyle(.red)
                }
            }
        } else {
            Button("Set file") {
                pickFileForTrack(trackEntity: trackEntity)
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
        }
    }

    private func pickFileForTrack(trackEntity: TrackEntity) {
#if os(macOS)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = libraryRootURL()
        panel.message = "Choose an audio file for this track"
        panel.prompt = "Select"
        if panel.runModal() == .OK, let url = panel.url {
            let path = url.path
            fileMatchCoordinator.assignFile(trackMBID: trackEntity.trackMBID, url: url)
            loadTrackEntities()
            // Skip analysis if file was already analyzed (e.g. re-assigning a known file)
            var fd = FetchDescriptor<LocalFileEntity>(predicate: #Predicate { $0.filePath == path })
            fd.fetchLimit = 1
            let alreadyAnalyzed = (try? modelContext.fetch(fd).first)
                .map { $0.bpm > 0 || $0.analyzedAt != nil } ?? false
            guard !alreadyAnalyzed else { return }
            analyzingTrackPath = path
            Task {
                _ = await localAnalysisCoordinator.analyzeSingleFile(path: path)
                loadTrackEntities()
                loadFeatureEntities()
                analyzingTrackPath = nil
            }
        }
#endif
    }

    private func libraryRootURL() -> URL? {
        guard let path = UserDefaults.standard.string(forKey: LocalLibraryService.displayPathKey) else { return nil }
        return URL(fileURLWithPath: path)
    }

    private func loadEntity() {
        let instanceId = item.id
        var descriptor = FetchDescriptor<CollectionItemEntity>(
            predicate: #Predicate { $0.instanceId == instanceId }
        )
        descriptor.fetchLimit = 1
        itemEntity = try? modelContext.fetch(descriptor).first
    }

    private func unlinkMBID(entity: CollectionItemEntity) {
        let tracksToDelete = entity.tracks
        for track in tracksToDelete {
            modelContext.delete(track)
        }
        scanCoordinator.resetToNotFound(instanceId: entity.instanceId)
        try? modelContext.save()
        loadEntity()
        loadTrackEntities()
        loadFeatureEntities()
    }

    private func loadTrackEntities() {
        guard let entity = itemEntity else { return }
        trackEntities = entity.tracks
    }

    private func loadFeatureEntities() {
        let mbids = Set(trackEntities.map(\.recordingMBID).filter { !$0.isEmpty })
        guard !mbids.isEmpty else { featureEntities = []; return }
        let all = (try? modelContext.fetch(FetchDescriptor<RecordingFeaturesEntity>())) ?? []
        featureEntities = all.filter { mbids.contains($0.recordingMBID) }
    }

    private func featuresEntity(forRecordingMBID rmbid: String) -> RecordingFeaturesEntity? {
        featureEntities.first { $0.recordingMBID == rmbid }
    }

    private func normalizePosition(_ s: String) -> String {
        s.replacingOccurrences(of: " ", with: "").uppercased()
    }

    private func recordingMBID(forPosition position: String, fallbackIndex: Int? = nil) -> String? {
        guard !position.isEmpty else { return nil }
        // Primary: exact position string match (works when both sides use same notation)
        let norm = normalizePosition(position)
        if let match = trackEntities.first(where: { normalizePosition($0.position) == norm }),
           !match.recordingMBID.isEmpty {
            return match.recordingMBID
        }
        // Fallback: index-based match — handles Discogs A1/B1 vs MusicBrainz 1/2/3
        if let idx = fallbackIndex {
            let sorted = trackEntitiesSortedNumerically
            if idx < sorted.count {
                let mbid = sorted[idx].recordingMBID
                return mbid.isEmpty ? nil : mbid
            }
        }
        return nil
    }

    // Track entities sorted numerically by position (1, 2, 3 … 10, 11) for index matching
    private var trackEntitiesSortedNumerically: [TrackEntity] {
        trackEntities.sorted {
            let a = Int($0.position) ?? Int.max
            let b = Int($1.position) ?? Int.max
            return a == b ? $0.position < $1.position : a < b
        }
    }

    @ViewBuilder
    private func orphanFeatureRow(trackEntity: TrackEntity) -> some View {
        if let bpm = trackEntity.effectiveBpm {
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Text("ES")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color(red: 0.15, green: 0.55, blue: 0.30)))
                    .help("BPM & key analyzed from your local audio file")
                    .accessibilityLabel("BPM & key analyzed from your local audio file")
                Text("\(Int(bpm)) BPM")
                    .font(.callout.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.primary)
                if let code = trackEntity.effectiveCamelot {
                    Text(code)
                        .font(.subheadline.weight(.bold).monospacedDigit())
                        .foregroundStyle(CamelotColor.text(for: code))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(CamelotColor.background(for: code)))
                }
            }
        }
    }

    private func recordingMBIDCaption(_ rmbid: String) -> some View {
        let short        = rmbid.count >= 8 ? String(rmbid.prefix(8)) + "…" : rmbid
        let features     = featuresEntity(forRecordingMBID: rmbid)
        let matchedTrack = trackEntities.first(where: { $0.recordingMBID == rmbid })

        // Local Essentia takes priority over AcousticBrainz
        let bpm: Double?
        let camelot: String?
        let source: TrackEntity.FeatureSource
        if let track = matchedTrack, let localBpm = track.effectiveBpm {
            bpm    = localBpm
            camelot = track.effectiveCamelot
            source  = .local
        } else if features?.bpm != nil || features?.camelotCode != nil {
            bpm    = features?.bpm
            camelot = features?.camelotCode
            source  = .ab
        } else {
            bpm    = nil
            camelot = nil
            source  = .none
        }

        return Button {
            #if os(macOS)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(rmbid, forType: .string)
            #else
            UIPasteboard.general.string = rmbid
            #endif
            copiedRecordingMBID = rmbid
            Task {
                try? await Task.sleep(for: .seconds(2))
                copiedRecordingMBID = nil
            }
        } label: {
            HStack(spacing: 8) {
                // REC hash — left side, understated
                Text(copiedRecordingMBID == rmbid ? "✓ Copied" : "REC: \(short)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)

                Spacer(minLength: 12)

                // Source pill — styled like the format pill
                if source == .local {
                    Text("ES")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color(red: 0.15, green: 0.55, blue: 0.30)))
                        .help("BPM & key analyzed from your local audio file")
                        .accessibilityLabel("BPM & key analyzed from your local audio file")
                } else if source == .ab {
                    Text("AB")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color(red: 0.35, green: 0.45, blue: 0.65)))
                        .help("BPM & key from the AcousticBrainz database")
                        .accessibilityLabel("BPM & key from the AcousticBrainz database")
                }

                // BPM — right side, prominent
                if let bpm {
                    Text("\(Int(bpm)) BPM")
                        .font(.callout.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.primary)
                }

                // Camelot pill — right side
                if let code = camelot {
                    Text(code)
                        .font(.subheadline.weight(.bold).monospacedDigit())
                        .foregroundStyle(CamelotColor.text(for: code))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(CamelotColor.background(for: code)))
                }

                // Format pill — shown when track has a confident local file match
                if matchedTrack?.fileMatchState == "confident",
                   let filePath = matchedTrack?.primaryLocalFilePath {
                    let ext = URL(fileURLWithPath: filePath).pathExtension.uppercased()
                    Text(ext)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color(red: 0.25, green: 0.50, blue: 0.90)))
                } else if matchedTrack?.fileMatchState == "review" {
                    Text("?")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.secondary.opacity(0.2)))
                }
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Inline audio player

    @ViewBuilder
    private func trackPlayerArea(filePath: String) -> some View {
        if let err = playback.playbackErrors[filePath] {
            Label(err, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(2)
                .textSelection(.enabled)
        } else {
            VStack(alignment: .leading, spacing: 3) {
                trackWaveformView(filePath: filePath)
                    .frame(height: 64)
                if playback.duration > 0 {
                    Text("\(formatTime(playback.currentTime)) / \(formatTime(playback.duration))")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func trackWaveformView(filePath: String) -> some View {
        let isActive = playback.currentFilePath == filePath
        let progress: Double = isActive && playback.duration > 0
            ? min(1, max(0, playback.currentTime / playback.duration))
            : 0.0
        switch playback.waveformState(for: filePath) {
        case .ready(let peaks):
            WaveformView(peaks: peaks,
                         colors: playback.waveformColors(filePath: filePath),
                         compact: true) { fraction in
                playback.seek(toFraction: fraction)
            }
            .equatable()
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(alignment: .leading) {
                if isActive {
                    GeometryReader { geo in
                        Rectangle()
                            .fill(Color.red)
                            .frame(width: 2.5)
                            .offset(x: geo.size.width * CGFloat(progress) - 1.25)
                            .allowsHitTesting(false)
                    }
                }
            }
        case .loading:
            ZStack {
                RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.1))
                HStack(spacing: 6) {
                    ProgressView().scaleEffect(0.6)
                    Text("Loading waveform…").font(.caption2).foregroundStyle(.secondary)
                }
            }
        case .failed:
            ZStack {
                RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.08))
                Text("Waveform unavailable").font(.caption2).foregroundStyle(.tertiary)
            }
        case .idle:
            Color.clear
                .onAppear { playback.loadWaveformIfNeeded(filePath: filePath) }
        }
    }

    private func formatTime(_ seconds: Double) -> String {
        let s = max(0, Int(seconds))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    // MARK: - Waveform prefetch

    private func prefetchWaveforms() {
        let paths = trackEntities
            .filter { $0.fileMatchState == "confident" }
            .compactMap { $0.primaryLocalFilePath }
            .filter { !$0.isEmpty }
        prefetchedPaths = paths
        for fp in paths {
            playback.loadWaveformIfNeeded(filePath: fp)
        }
    }

    // MARK: - Data loading

    private func load() async {
        isLoading = true
        loadError = nil
        detail = nil
        defer { isLoading = false }
        do {
            let loaded = try await viewModel.loadDetail(for: item)
            detail = loaded
            // Populate gallery from parsed images array, fallback to primary cover
            if let images = loaded.images, !images.isEmpty {
                galleryURLs = images.map { $0.uri }
            } else {
                let primary = item.basicInformation.coverImage
                let thumb   = item.basicInformation.thumb
                galleryURLs = !primary.isEmpty ? [primary] : (!thumb.isEmpty ? [thumb] : [])
            }
            galleryIndex = 0
        } catch {
            loadError = error.localizedDescription
        }
    }
}
