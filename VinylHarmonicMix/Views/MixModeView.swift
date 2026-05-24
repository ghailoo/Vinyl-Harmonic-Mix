import SwiftUI
import SwiftData
import AppKit

enum MixScope: String, CaseIterable {
    case confident   = "Discogs collection"
    case allAnalyzed = "All analyzed"
}

struct MixModeView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(CollectionViewModel.self) private var viewModel
    @Environment(AudioPlaybackController.self) private var playback

    @Query(sort: \SetlistEntity.createdAt, order: .reverse)
    private var allSets: [SetlistEntity]

    @State private var activeSet: SetlistEntity?
    @State private var scope: MixScope = .confident

    @AppStorage("collectionGridCardSize") private var cardSize: Double = 0.25

    private var gridColumns: [GridItem] {
        let minWidth = 120.0 + cardSize * 160.0
        return [GridItem(.adaptive(minimum: minWidth, maximum: minWidth + 40), spacing: 16)]
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            deckShell
            Divider()
            coverGrid
        }
        .onChange(of: allSets) { _, newSets in
            if let active = activeSet, !newSets.contains(active) {
                activeSet = nil
            }
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(spacing: 12) {
            setPickerMenu
            Spacer()
            Picker("Scope", selection: $scope) {
                ForEach(MixScope.allCases, id: \.self) { s in
                    Text(s.rawValue).tag(s)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 280)
            .labelsHidden()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.secondary.opacity(0.04))
    }

    // MARK: - Set picker menu

    private var setPickerMenu: some View {
        Menu {
            ForEach(allSets) { set in
                Button {
                    activeSet = set
                } label: {
                    HStack {
                        Text(set.name)
                        if activeSet == set {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
            if !allSets.isEmpty { Divider() }
            Button {
                createAndSelectNewSet()
            } label: {
                Label("New set…", systemImage: "plus")
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "list.bullet.rectangle")
                    .font(.system(size: 12, weight: .semibold))
                Text(activeSet?.name ?? "Select a set…")
                    .font(.system(size: 13))
                Image(systemName: "chevron.down")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(activeSet != nil
                ? Color.accentColor.opacity(0.12)
                : Color.secondary.opacity(0.12)))
            .overlay(Capsule().strokeBorder(
                activeSet != nil ? Color.accentColor.opacity(0.3) : Color.secondary.opacity(0.2),
                lineWidth: 0.5))
            .foregroundStyle(activeSet != nil ? Color.accentColor : Color.primary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
    }

    // MARK: - Deck shell (Stage B: Deck A = anchor from active set, Deck B = empty)

    @ViewBuilder
    private var deckShell: some View {
        let anchor = anchorTrack
        HStack(alignment: .center, spacing: 6) {
            deckPanel(label: "DECK A — ANCHOR", track: anchor)
            Color.clear.frame(width: 62)  // transition bubble slot — wired in Stage C
            deckPanel(label: "DECK B — NEXT", track: nil)
        }
        .padding(12)
        .background(Color.secondary.opacity(0.03))
    }

    // MARK: - Cover grid (Stage B: always Discogs collection, no-op click)

    private var coverGrid: some View {
        ScrollView {
            LazyVGrid(columns: gridColumns, spacing: 20) {
                ForEach(viewModel.items) { item in
                    CollectionCardView(
                        item: item,
                        hasMBID: false,
                        covered: 0,
                        total: 0,
                        localCovered: 0,
                        isActive: false
                    )
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Anchor track

    private var anchorTrack: MixTrack? {
        guard let set = activeSet else { return nil }
        let sorted = set.items.sorted { $0.position < $1.position }
        guard let last = sorted.last else { return nil }
        return MixTrack(
            displayArtist: last.displayArtist,
            displayTitle:  last.displayTitle,
            bpm:           last.bpm,
            camelot:       last.camelot,
            key:           last.key,
            source:        .local,
            filePath:      last.filePath.isEmpty ? nil : last.filePath
        )
    }

    // MARK: - Deck panel

    @ViewBuilder
    private func deckPanel(label: String, track: MixTrack?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .kerning(0.5)
            if let t = track {
                HStack(spacing: 6) {
                    camelotPill(t.camelot, fontSize: 9)
                    Text("\(Int(t.bpm.rounded())) BPM")
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    if !t.key.isEmpty {
                        Text(t.key)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let fp = t.filePath {
                        playButton(fp, fontSize: 16)
                    }
                }
                Text(t.displayTitle)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Text(t.displayArtist)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let fp = t.filePath {
                    TrackWaveformView(filePath: fp)
                        .id(fp)
                        .padding(.horizontal, -16)
                }
            } else {
                Text("—")
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: 52)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06)))
    }

    // MARK: - Create new set

    private func createAndSelectNewSet() {
        let newSet = SetlistEntity()
        modelContext.insert(newSet)
        try? modelContext.save()
        activeSet = newSet
    }

    // MARK: - Sub-components

    @ViewBuilder
    private func playButton(_ filePath: String, fontSize: CGFloat) -> some View {
        Button { playback.play(filePath: filePath) } label: {
            let isActive  = playback.currentFilePath == filePath
            let isPlaying = isActive && playback.isPlaying
            Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                .font(.system(size: fontSize))
                .foregroundStyle(isActive ? Color.accentColor : Color.secondary.opacity(0.5))
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func camelotPill(_ code: String, fontSize: CGFloat) -> some View {
        Text(code)
            .font(.system(size: fontSize, weight: .bold).monospacedDigit())
            .foregroundStyle(CamelotColor.text(for: code))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Capsule().fill(CamelotColor.background(for: code)))
    }
}
