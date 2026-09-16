import SwiftUI
import SwiftData
import AppKit

struct SetLibraryView: View {
    let setlist: SetlistEntity

    @Environment(\.modelContext) private var modelContext
    @Environment(AudioPlaybackController.self) private var playback

    @State private var showCopiedFeedback: Bool = false

    private var isPlayingThrough: Bool { !playback.playingSetItems.isEmpty }
    private var playThroughIndex: Int  { playback.playingSetIndex }

    // MARK: - Computed

    private var sortedItems: [SetlistItemEntity] {
        setlist.items.sorted { $0.position < $1.position }
    }

    private var journeySummary: String {
        let items = sortedItems
        guard !items.isEmpty else { return "" }
        let bpms = items.map { $0.bpm }
        let lo = Int((bpms.min() ?? 0).rounded())
        let hi = Int((bpms.max() ?? 0).rounded())
        let bpmStr = lo == hi ? "\(lo) BPM" : "\(lo)–\(hi) BPM"
        let camelotPath = items.map { $0.camelot }.joined(separator: " → ")
        return "\(bpmStr) · \(camelotPath)"
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            if sortedItems.isEmpty {
                emptyState
            } else {
                headerBar
                Divider()
                trackList
            }
        }
    }

    // MARK: - Header bar

    private var headerBar: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                let count = sortedItems.count
                Text("\(count) track\(count == 1 ? "" : "s")")
                    .font(.system(size: 11, weight: .semibold))
                Text(journeySummary)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Button(action: isPlayingThrough ? { playback.stopSet(); playback.pause() } : { playback.startSet(sortedItems) }) {
                Label(isPlayingThrough ? "Stop" : "Play Set",
                      systemImage: isPlayingThrough ? "stop.fill" : "play.fill")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button(action: copyTracklist) {
                Label(showCopiedFeedback ? "Copied!" : "Copy Tracklist",
                      systemImage: showCopiedFeedback ? "checkmark" : "doc.on.clipboard")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(showCopiedFeedback)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.secondary.opacity(0.04))
    }

    // MARK: - Track list

    private var trackList: some View {
        List {
            ForEach(Array(sortedItems.enumerated()), id: \.element.persistentModelID) { idx, item in
                trackRow(item: item, idx: idx)
                    .listRowInsets(EdgeInsets(top: 2, leading: 12, bottom: 2, trailing: 10))
            }
            .onMove { from, to in reorderItems(from: from, to: to) }
        }
        .listStyle(.plain)
    }

    // MARK: - Track row

    @ViewBuilder
    private func trackRow(item: SetlistItemEntity, idx: Int) -> some View {
        let items = sortedItems
        let total = items.count
        let isNowPlaying = isPlayingThrough
            && !item.filePath.isEmpty
            && playback.currentFilePath == item.filePath

        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("\(idx + 1)")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 20, alignment: .trailing)
                camelotPill(item.camelot, fontSize: 9)
                Text("\(Int(item.bpm.rounded()))")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 28, alignment: .trailing)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.displayTitle)
                        .font(.system(size: 12))
                        .lineLimit(1)
                    Text(item.displayArtist)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if isNowPlaying {
                    Image(systemName: playback.isPlaying ? "speaker.wave.2.fill" : "speaker.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.accentColor)
                        .symbolEffect(.variableColor, isActive: playback.isPlaying)
                }
                if idx == total - 1 && total > 1 {
                    Text("last")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.secondary.opacity(0.5)))
                }
                Button(role: .destructive) { removeItem(item) } label: {
                    Image(systemName: "minus.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.red.opacity(0.65))
                }
                .buttonStyle(.plain)
                .help("Remove from set")
                .accessibilityLabel("Remove from set")
            }
            .padding(.vertical, 4)

            if idx < total - 1 {
                let next = items[idx + 1]
                let info = transitionInfo(from: item, to: next)
                HStack(spacing: 6) {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.25))
                        .frame(width: 1, height: 10)
                        .padding(.leading, 23)
                    Text("\(info.bpmDelta) · \(info.label)")
                        .font(.system(size: 10))
                        .foregroundStyle(info.group?.color ?? Color.secondary.opacity(0.7))
                }
                .padding(.bottom, 2)
            }
        }
        .listRowBackground(isNowPlaying ? Color.accentColor.opacity(0.07) : Color.clear)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "music.note.list")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("No tracks in this set")
                .font(.title3)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Reorder + Remove

    private func reorderItems(from source: IndexSet, to destination: Int) {
        var items = sortedItems
        items.move(fromOffsets: source, toOffset: destination)
        for (newPos, item) in items.enumerated() {
            item.position = newPos
        }
        try? modelContext.save()
        if isPlayingThrough { playback.stopSet(); playback.pause() }
    }

    private func removeItem(_ item: SetlistItemEntity) {
        let remaining = sortedItems.filter { $0.persistentModelID != item.persistentModelID }
        modelContext.delete(item)
        for (newPos, track) in remaining.enumerated() {
            track.position = newPos
        }
        try? modelContext.save()
        if isPlayingThrough && remaining.isEmpty { playback.stopSet(); playback.pause() }
    }

    // MARK: - Text export

    private func copyTracklist() {
        let items = sortedItems
        var lines = [setlist.name]
        for (i, item) in items.enumerated() {
            lines.append("\(i + 1). \(item.displayArtist) – \(item.displayTitle) (\(Int(item.bpm.rounded())) BPM, \(item.camelot))")
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
        showCopiedFeedback = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            showCopiedFeedback = false
        }
    }

    // MARK: - Transition helper

    private func transitionInfo(from: SetlistItemEntity, to: SetlistItemEntity) -> TransitionInfo {
        VinylHarmonicMix.transitionInfo(fromCamelot: from.camelot, fromBPM: from.bpm,
                                        toCamelot: to.camelot, toBPM: to.bpm)
    }

    // MARK: - Sub-components

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
