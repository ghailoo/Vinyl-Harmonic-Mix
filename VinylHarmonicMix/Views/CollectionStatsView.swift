import SwiftUI
import SwiftData

struct CollectionStatsView: View {
    @Query private var entities: [CollectionItemEntity]
    @Query private var detailEntities: [ReleaseDetailEntity]

    @State private var cachedDetails: [ReleaseDetail] = []
    @State private var showPrewarmAlert = false

    var body: some View {
        Group {
            if entities.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "tray")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                    Text("Import your collection first.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Stats")
                            .font(.system(size: 28, weight: .bold))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.bottom, 4)

                        heroCard

                        if !formatCounts.isEmpty  { formatCard }
                        if !genreCounts.isEmpty   { genreCard }
                        if !decadeCounts.isEmpty  { decadeCard }
                        if !labelCounts.isEmpty   { labelsCard }
                        if !artistCounts.isEmpty  { artistsCard }
                        tracksCard
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 20)
                }
            }
        }
        .navigationTitle("Stats")
        .task(id: detailEntities.count) {
            cachedDetails = detailEntities.compactMap {
                try? JSONDecoder().decode(ReleaseDetail.self, from: $0.jsonData)
            }
        }
        .alert("Pre-warm coming soon", isPresented: $showPrewarmAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Pre-warming will be added in the next milestone (~15 min Discogs scan).")
        }
    }

    // MARK: - Card wrapper

    private func sectionCard<Content: View>(accent: Bool = false, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .padding(20)
        .background(
            accent ? Color.accentColor.opacity(0.06) : Color.secondary.opacity(0.06),
            in: RoundedRectangle(cornerRadius: 12)
        )
    }

    // MARK: - Section header

    @ViewBuilder
    private func sectionHeader(title: String, total: Int? = nil, shown: Int? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 17, weight: .semibold))
            if let total, let shown, shown < total {
                Text("\(shown) of \(total) unique")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.bottom, 12)
    }

    // MARK: - Hero card

    private var heroCard: some View {
        sectionCard {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 16) {
                statTile(value: entities.count.formatted(), label: "releases", accent: false)
                statTile(value: matchedCount.formatted(), label: "matched", accent: true)
                statTile(value: yearRangeLabel, label: "year range", accent: false)
                statTile(value: medianAge > 0 ? "\(medianAge) years" : "—", label: "median age", accent: false)
            }
        }
    }

    private func statTile(value: String, label: String, accent: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.system(size: 32, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(accent ? Color.accentColor : Color.primary)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Format card

    private var formatCard: some View {
        sectionCard {
            sectionHeader(title: "Releases by format")
            VStack(spacing: 6) {
                ForEach(Array(formatCounts.enumerated()), id: \.offset) { _, item in
                    HStack(spacing: 8) {
                        Image(systemName: formatIcon(for: item.label))
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                            .frame(width: 18, alignment: .center)
                        Text(item.label)
                            .font(.system(size: 14))
                        Spacer()
                        Text(item.count.formatted())
                            .font(.system(size: 14).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 50, alignment: .trailing)
                    }
                }
            }
        }
    }

    private func formatIcon(for name: String) -> String {
        let lower = name.lowercased()
        if lower.contains("vinyl") || lower.contains("lp") || lower.contains("ep")
            || lower == "12\"" || lower == "10\"" || lower == "7\"" { return "circle.dotted" }
        if lower.contains("cd") || lower.contains("optical") { return "opticaldisc" }
        if lower.contains("cassette") || lower.contains("tape") { return "mediastick" }
        if lower.contains("box") || lower.contains("set") { return "square.stack.3d.up" }
        if lower.contains("file") || lower.contains("digital")
            || lower.contains("mp3") || lower.contains("flac") { return "waveform" }
        return "square"
    }

    // MARK: - Genre card

    private var genreCard: some View {
        let all = genreCounts
        let shown = Array(all.prefix(8))
        return sectionCard {
            sectionHeader(title: "Releases by genre", total: all.count, shown: shown.count)
            VStack(spacing: 6) {
                ForEach(Array(shown.enumerated()), id: \.offset) { _, item in
                    HStack {
                        Text(item.label).font(.system(size: 14))
                        Spacer()
                        Text(item.count.formatted())
                            .font(.system(size: 14).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 50, alignment: .trailing)
                    }
                }
            }
        }
    }

    // MARK: - Decade card

    private var decadeCard: some View {
        let items = decadeCounts
        let maxCount = items.map(\.count).max() ?? 1
        return sectionCard {
            sectionHeader(title: "Releases by decade")
            VStack(spacing: 10) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    decadeRow(decade: item.label, count: item.count, maxCount: maxCount)
                }
            }
        }
    }

    private func decadeRow(decade: String, count: Int, maxCount: Int) -> some View {
        HStack(spacing: 12) {
            Text(decade)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 60, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.secondary.opacity(0.15))
                        .frame(height: 8)
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(
                            width: maxCount > 0
                                ? geo.size.width * CGFloat(count) / CGFloat(maxCount)
                                : 0,
                            height: 8
                        )
                }
            }
            .frame(height: 8)
            Text(count.formatted())
                .font(.system(size: 13).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 50, alignment: .trailing)
        }
    }

    // MARK: - Labels card

    private var labelsCard: some View {
        let items = labelCounts
        return sectionCard {
            sectionHeader(title: "Top labels by releases")
            VStack(spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(spacing: 8) {
                        Text("\(index + 1)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.tertiary)
                            .frame(width: 20, alignment: .trailing)
                        Text(item.label).font(.system(size: 14))
                        Spacer()
                        Text(item.count.formatted())
                            .font(.system(size: 14).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 50, alignment: .trailing)
                    }
                }
            }
        }
    }

    // MARK: - Artists card

    private var artistsCard: some View {
        let items = artistCounts
        return sectionCard {
            sectionHeader(title: "Top artists by releases")
            VStack(spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(spacing: 8) {
                        Text("\(index + 1)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.tertiary)
                            .frame(width: 20, alignment: .trailing)
                        Text(item.label).font(.system(size: 14))
                        Spacer()
                        Text(item.count.formatted())
                            .font(.system(size: 14).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 50, alignment: .trailing)
                    }
                }
            }
        }
    }

    // MARK: - Tracks card

    private var tracksCard: some View {
        let allCached = cachedDetailCount > 0 && cachedDetailCount == entities.count
        return sectionCard(accent: true) {
            HStack(spacing: 6) {
                Text("Tracks & duration")
                    .font(.system(size: 17, weight: .semibold))
                if cachedDetailCount > 0 && !allCached {
                    HStack(spacing: 4) {
                        Image(systemName: "info.circle").font(.caption)
                        Text("Partial data").font(.caption)
                    }
                    .foregroundStyle(.tertiary)
                }
                Spacer()
            }
            .padding(.bottom, 12)

            if cachedDetailCount == 0 {
                Text("No detail data yet. Caching will fetch tracklists, credits, and notes for all \(entities.count.formatted()) releases (~15 min).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    if allCached {
                        Text("\(cachedTrackCount.formatted()) tracks across all \(entities.count.formatted()) releases")
                            .font(.system(size: 14))
                    } else {
                        Text("\(cachedTrackCount.formatted()) tracks across \(cachedDetailCount.formatted()) of \(entities.count.formatted()) releases (\(cachePercent)%)")
                            .font(.system(size: 14))
                        if let est = estimatedTotalTracks {
                            Text("Estimated total: \(est.formatted()) tracks (extrapolated)")
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text("Recorded duration: \(cachedDurationLabel) (from cached data)")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
            }

            Button(allCached && entities.count > 0 ? "Refresh detail cache" : "Cache all release details") {
                showPrewarmAlert = true
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .padding(.top, 10)
        }
    }

    // MARK: - Computed stats

    private var matchedCount: Int {
        entities.filter {
            $0.mbidScanState == "matched" || $0.mbidScanState == "matchedViaSearch"
        }.count
    }

    private var validYears: [Int] {
        entities.compactMap { $0.basicInformation?.year }.filter { $0 > 0 }
    }

    private var yearRangeLabel: String {
        guard let minY = validYears.min(), let maxY = validYears.max() else { return "—" }
        return "\(minY)–\(maxY)"
    }

    private var medianAge: Int {
        let sorted = validYears.sorted()
        guard !sorted.isEmpty else { return 0 }
        let median = sorted[sorted.count / 2]
        return Calendar.current.component(.year, from: Date()) - median
    }

    private var formatCounts: [(label: String, count: Int)] {
        var counts: [String: Int] = [:]
        for entity in entities {
            let name = entity.basicInformation?.formats.first?.name ?? "Unknown"
            counts[name, default: 0] += 1
        }
        return counts.sorted { $0.value > $1.value }.map { (label: $0.key, count: $0.value) }
    }

    private var genreCounts: [(label: String, count: Int)] {
        var counts: [String: Int] = [:]
        for entity in entities {
            for genre in entity.basicInformation?.genres ?? [] {
                counts[genre, default: 0] += 1
            }
        }
        return counts.sorted { $0.value > $1.value }.map { (label: $0.key, count: $0.value) }
    }

    private var decadeCounts: [(label: String, count: Int)] {
        var counts: [Int: Int] = [:]
        for entity in entities {
            guard let year = entity.basicInformation?.year, year > 0 else { continue }
            let decade = (year / 10) * 10
            counts[decade, default: 0] += 1
        }
        return counts.sorted { $0.key < $1.key }.map { (label: "\($0.key)s", count: $0.value) }
    }

    private var labelCounts: [(label: String, count: Int)] {
        var counts: [String: Int] = [:]
        for entity in entities {
            guard let name = entity.basicInformation?.labels.first?.name else { continue }
            counts[name, default: 0] += 1
        }
        return counts.sorted { $0.value > $1.value }.prefix(10).map { (label: $0.key, count: $0.value) }
    }

    private var artistCounts: [(label: String, count: Int)] {
        let excluded: Set<String> = ["various", "various artists", "unknown artist"]
        var counts: [String: Int] = [:]
        for entity in entities {
            guard let name = entity.basicInformation?.artists.first?.name else { continue }
            guard !excluded.contains(name.lowercased()) else { continue }
            counts[name, default: 0] += 1
        }
        return counts.sorted { $0.value > $1.value }.prefix(10).map { (label: $0.key, count: $0.value) }
    }

    // MARK: - Track stats

    private var cachedDetailCount: Int { cachedDetails.count }

    private var cachedTrackCount: Int {
        cachedDetails.reduce(0) { $0 + $1.tracklist.count }
    }

    private var cachedDurationSeconds: Int {
        cachedDetails.flatMap(\.tracklist).reduce(0) { total, track in
            total + parseDuration(track.duration)
        }
    }

    private var estimatedTotalTracks: Int? {
        guard cachedDetailCount > 0 else { return nil }
        return (cachedTrackCount / cachedDetailCount) * entities.count
    }

    private var cachePercent: Int {
        guard entities.count > 0 else { return 0 }
        return cachedDetailCount * 100 / entities.count
    }

    private var cachedDurationLabel: String {
        let h = cachedDurationSeconds / 3600
        let m = (cachedDurationSeconds % 3600) / 60
        if h > 0 { return "\(h) h \(m) min" }
        let s = cachedDurationSeconds % 60
        return "\(m) min \(s) sec"
    }

    private func parseDuration(_ s: String) -> Int {
        guard !s.isEmpty else { return 0 }
        let parts = s.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return 0 }
        return parts[0] * 60 + parts[1]
    }
}
