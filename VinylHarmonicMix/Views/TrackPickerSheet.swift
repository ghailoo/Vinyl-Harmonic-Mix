import SwiftUI
import SwiftData

// MARK: - Track picker sheet

struct TrackPickerSheet: View {
    let entity: CollectionItemEntity
    let onPick: (MixTrack) -> Void

    @Environment(\.dismiss) private var dismiss

    private var mixableTracks: [TrackEntity] {
        entity.tracks
            .filter { $0.effectiveBpm != nil && !($0.effectiveCamelot ?? "").isEmpty }
            .sorted { $0.position < $1.position }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entity.basicInformation?.title ?? "Release").font(.headline)
                    Text("\(mixableTracks.count) mixer-ready track\(mixableTracks.count == 1 ? "" : "s")")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }
            }
            .padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 12)

            Divider()

            if mixableTracks.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "waveform.slash").font(.iconLarge).foregroundStyle(.tertiary)
                    Text("No tracks with BPM and key data").foregroundStyle(.secondary)
                    Text("Run audio analysis to make tracks mixer-ready.")
                        .font(.caption).foregroundStyle(.tertiary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                List(mixableTracks, id: \.trackMBID) { track in
                    Button {
                        let mix = MixTrack(
                            displayArtist: track.artistCredit,
                            displayTitle:  track.title,
                            bpm:           track.effectiveBpm ?? 0,
                            camelot:       track.effectiveCamelot ?? "",
                            key:           track.effectiveKey ?? "",
                            source:        track.featureSource,
                            filePath:      track.primaryLocalFilePath,
                            label:         entity.basicInformation?.labels.first?.name ?? "",
                            year:          entity.basicInformation?.year ?? 0
                        )
                        onPick(mix)
                        dismiss()
                    } label: {
                        HStack(spacing: 10) {
                            Text(track.position)
                                .font(.callout.weight(.semibold).monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 28, alignment: .trailing)
                            if let bpm = track.effectiveBpm, let cam = track.effectiveCamelot {
                                camelotPill(cam)
                                Text("\(Int(bpm.rounded()))")
                                    .font(.callout.weight(.semibold).monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 32, alignment: .trailing)
                            }
                            VStack(alignment: .leading, spacing: 1) {
                                Text(track.title).font(.body).lineLimit(1)
                                if !track.artistCredit.isEmpty {
                                    Text(track.artistCredit)
                                        .font(.callout).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            Spacer()
                            Image(systemName: "plus.circle")
                                .font(.body)
                                .foregroundStyle(Color.accentColor.opacity(0.7))
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowInsets(EdgeInsets(top: 3, leading: 12, bottom: 3, trailing: 12))
                }
                .listStyle(.plain)
            }
        }
        .frame(minWidth: 460, minHeight: 340)
    }

    @ViewBuilder
    private func camelotPill(_ code: String) -> some View {
        Text(code)
            .font(.subheadline.weight(.bold).monospacedDigit())
            .foregroundStyle(CamelotColor.text(for: code))
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(Capsule().fill(CamelotColor.background(for: code)))
    }
}

// MARK: - Deck A release picker

struct DeckAReleasePicker: View {
    let allEntities: [CollectionItemEntity]
    let mixableCount: [Int: Int]
    let onPick: (MixTrack) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var searchText: String = ""
    @State private var selectedRelease: CollectionItemEntity? = nil

    private var mixableEntities: [CollectionItemEntity] {
        let candidates = allEntities.filter { (mixableCount[$0.instanceId] ?? 0) > 0 }
        let q = searchText.trimmingCharacters(in: .whitespaces)
        let filtered = q.isEmpty ? candidates : candidates.filter { entity in
            let title   = entity.basicInformation?.title ?? ""
            let artists = entity.basicInformation?.artists.map(\.name).joined(separator: " ") ?? ""
            let lower   = q.lowercased()
            return title.lowercased().contains(lower) || artists.lowercased().contains(lower)
        }
        return filtered.sorted {
            ($0.basicInformation?.title ?? "") < ($1.basicInformation?.title ?? "")
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Pick opening track").font(.headline)
                    Text("\(mixableEntities.count) release\(mixableEntities.count == 1 ? "" : "s") with mixer-ready tracks")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }
            }
            .padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 12)

            Divider()

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.body).foregroundStyle(.secondary)
                TextField("Search releases…", text: $searchText).textFieldStyle(.plain).font(.body)
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.body)
                            .foregroundStyle(Color.secondary.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                    .help("Clear search")
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Color.secondary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .padding(.horizontal, 14).padding(.vertical, 8)

            List(mixableEntities, id: \.instanceId) { entity in
                Button { selectedRelease = entity } label: {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entity.basicInformation?.title ?? "Unknown")
                                .font(.body.weight(.semibold)).lineLimit(1)
                            Text(entity.basicInformation?.artists.map(\.name).joined(separator: " & ") ?? "")
                                .font(.callout).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        let count = mixableCount[entity.instanceId] ?? 0
                        Text("\(count) track\(count == 1 ? "" : "s")")
                            .font(.callout).foregroundStyle(.secondary)
                        Image(systemName: "chevron.right")
                            .font(.subheadline).foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowInsets(EdgeInsets(top: 5, leading: 14, bottom: 5, trailing: 14))
            }
            .listStyle(.plain)
        }
        .frame(minWidth: 460, minHeight: 420)
        .sheet(item: $selectedRelease) { entity in
            TrackPickerSheet(entity: entity) { track in
                onPick(track)
            }
        }
    }
}
