import Foundation

// Pairs the audio files of ONE folder with the tracks of ONE release ("Link folder…").
// Much narrower than the library-wide scorer, so it ranks in a fixed order of trust:
// leading track number in the filename, then title similarity, then duration.
// Pure and nonisolated — proposals only; nothing is written until the user confirms.
nonisolated enum ReleaseFolderMatcher {

    struct TrackInfo: Sendable, Equatable {
        let trackMBID: String     // MusicBrainz id or surrogate "discogs:…" id — only used as a key
        let position: String      // "3", "A2", "1-03" …
        let title: String
        let durationMs: Int       // 0 = unknown
    }

    struct FileInfo: Sendable, Equatable {
        let path: String
        let fileName: String
        let durationMs: Int       // <= 0 = unknown / unreadable
    }

    enum Reason: String, Sendable {
        case order    // file count == track count and the numbering is a clean run → straight 1:1
        case number   // leading number / vinyl side token in the filename matches the track
        case title    // title similarity only
    }

    struct Proposal: Sendable, Equatable {
        let trackMBID: String
        let filePath: String
        let reason: Reason
        let titleScore: Double
        let durationDiffSec: Int?  // nil when either duration is unknown
    }

    /// Minimum title similarity for a title-only proposal.
    static let titleThreshold = 0.5
    /// Durations within this many seconds count as agreeing.
    static let durationToleranceSec = 5

    /// `tracks` must be in tracklist order. Returns at most one proposal per track and per file,
    /// in track order; tracks with no plausible file are simply absent.
    static func propose(tracks: [TrackInfo], files: [FileInfo]) -> [Proposal] {
        guard !tracks.isEmpty, !files.isEmpty else { return [] }
        let tokens = files.map { leadingToken($0.fileName) }

        // Numbering is only trusted when every numbered file has its own number — "1-01" and
        // "2-01" on a two-disc folder both read as 1, so number matching is switched off there.
        let present = tokens.compactMap { $0 }
        let numbersUsable = Set(present).count == present.count

        if let ordered = straightOrder(tracks: tracks, files: files, tokens: tokens) { return ordered }

        struct Pair { let track: Int; let file: Int; let score: Double; let proposal: Proposal }
        var pairs: [Pair] = []
        for (ti, track) in tracks.enumerated() {
            let trackBase = FuzzyMatch.splitVersion(track.title).base
            let trackTokens = Set(trackBase.split(separator: " ").map(String.init))
            for (fi, file) in files.enumerated() {
                let numberHit = numbersUsable
                    && tokens[fi].map { tokenMatches($0, position: track.position, ordinal: ti + 1) } == true
                let title = titleScore(trackTokens: trackTokens, fileName: file.fileName)
                guard numberHit || title >= titleThreshold else { continue }
                let diff = durationDiffSec(track.durationMs, file.durationMs)
                let durationAgrees = diff.map { $0 <= durationToleranceSec } ?? false
                // Weights keep the trust order: a number hit outranks any title, and duration
                // only separates titles that are within a third of each other.
                let score = (numberHit ? 10 : 0) + title * 3 + (durationAgrees ? 1 : 0)
                pairs.append(Pair(track: ti, file: fi, score: score,
                                  proposal: Proposal(trackMBID: track.trackMBID, filePath: file.path,
                                                     reason: numberHit ? .number : .title,
                                                     titleScore: title, durationDiffSec: diff)))
            }
        }

        // Greedy best-first. ponytail: greedy, not optimal assignment — fine at release scale
        // (≤ ~40 tracks), switch to Hungarian if a real folder ever produces a bad swap.
        pairs.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            if a.track != b.track { return a.track < b.track }
            return files[a.file].fileName.localizedStandardCompare(files[b.file].fileName) == .orderedAscending
        }
        var usedTracks = Set<Int>(), usedFiles = Set<Int>()
        var chosen: [Int: Proposal] = [:]
        for p in pairs where !usedTracks.contains(p.track) && !usedFiles.contains(p.file) {
            usedTracks.insert(p.track); usedFiles.insert(p.file)
            chosen[p.track] = p.proposal
        }
        return tracks.indices.compactMap { chosen[$0] }
    }

    // MARK: - Pieces (internal for tests)

    /// Leading track token of a filename: "03 - Title.flac" → "3", "A2. Title.mp3" → "A2",
    /// "Title.flac" → nil. Digits only count when followed by a separator, so "10cc - …" is nil.
    static func leadingToken(_ fileName: String) -> String? {
        let stem = URL(fileURLWithPath: fileName).deletingPathExtension().lastPathComponent
        guard let m = stem.firstMatch(of: #/^\s*([A-Za-z]?)(\d{1,3})(?=[\s._\-)\]]|$)/#) else { return nil }
        let number = String(Int(m.output.2) ?? 0)
        return m.output.1.isEmpty ? number : m.output.1.uppercased() + number
    }

    static func tokenMatches(_ token: String, position: String, ordinal: Int) -> Bool {
        if let n = Int(token) {
            // Files are numbered by running order (vinyl A1…B4 → 01…08) or by the numeric position.
            return n == ordinal || n == Int(position.trimmingCharacters(in: .whitespaces))
        }
        let pos = position.replacingOccurrences(of: " ", with: "").uppercased()
        guard let m = pos.firstMatch(of: #/^([A-Z])0*(\d+)$/#) else { return false }
        return token == m.output.1 + m.output.2
    }

    /// Title part only, via FuzzyMatch; mix/version parentheticals are left out on both sides.
    static func titleScore(trackTokens: Set<String>, fileName: String) -> Double {
        // stemAndVersion strips a leading "03 - " and an "Artist - " prefix; strip "A2 " first too.
        let name = fileName.replacingOccurrences(of: #"^\s*[A-Za-z]\d{1,2}[\s.\-_]+"#,
                                                 with: "", options: .regularExpression)
        let stemTokens = FileMatchCoordinator.stemAndVersion(fileName: name).stemTokens
        return FuzzyMatch.similarity(tokensA: trackTokens, tokensB: stemTokens)
    }

    static func durationDiffSec(_ trackMs: Int, _ fileMs: Int) -> Int? {
        guard trackMs > 0, fileMs > 0 else { return nil }
        return abs(trackMs - fileMs) / 1000
    }

    /// The straight 1:1 mapping, offered only when it is unambiguous: as many files as tracks,
    /// every file numbered, and the numbers a gap-free run (1…8, or 101…108). Repeated positions
    /// (MusicBrainz multi-disc: "1"…"10" per disc) make the track order itself ambiguous → no.
    private static func straightOrder(tracks: [TrackInfo], files: [FileInfo], tokens: [String?]) -> [Proposal]? {
        guard files.count == tracks.count,
              Set(tracks.map(\.position)).count == tracks.count else { return nil }
        let numbers = tokens.compactMap { $0.flatMap(Int.init) }
        guard numbers.count == files.count, let first = numbers.min(),
              Set(numbers) == Set(first ..< first + numbers.count) else { return nil }
        let byNumber = zip(numbers, files).sorted { $0.0 < $1.0 }.map(\.1)
        return zip(tracks, byNumber).map { track, file in
            let trackBase = FuzzyMatch.splitVersion(track.title).base
            let title = titleScore(trackTokens: Set(trackBase.split(separator: " ").map(String.init)),
                                   fileName: file.fileName)
            return Proposal(trackMBID: track.trackMBID, filePath: file.path, reason: .order,
                            titleScore: title, durationDiffSec: durationDiffSec(track.durationMs, file.durationMs))
        }
    }
}
