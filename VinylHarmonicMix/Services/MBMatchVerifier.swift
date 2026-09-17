import Foundation

/// Named thresholds for the search pipeline (B3) — kept in one place so tuning doesn't
/// mean hunting through the pipeline for magic numbers.
enum MBMatchThresholds {
    /// Composite score at/above which a fuzzy (non-identifier) candidate auto-accepts.
    static let strongFuzzyAutoAccept = 0.85
    /// Composite score at/above which a candidate is worth surfacing for manual review.
    static let reviewMinimum = 0.55
    /// Year difference still treated as a close-enough match (boosted, not rejected).
    static let yearToleranceYears = 1
}

/// Local verification/scoring for MusicBrainz search candidates (B2). Pure and network-free —
/// reuses `FuzzyMatch.normalize`/`splitVersion`/`similarity` rather than re-implementing them.
enum MBMatchVerifier {

    struct DiscogsSide {
        let artists: [String]
        let title: String
        let formats: [String]
        var catalogNumber: String?
        let country: String?
        let year: Int?
        let trackCount: Int?
    }

    /// Discogs artist credits get a numeric disambiguation suffix when multiple Discogs
    /// artists share a name, e.g. "Madonna (2)" — strip it before querying/comparing (B1).
    static func stripDiscogsArtistSuffix(_ name: String) -> String {
        name.replacingOccurrences(of: #"\s*\(\d+\)\s*$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    static func isVinylFormat(_ formats: [String]) -> Bool {
        formats.contains { format in
            let lower = format.lowercased()
            return lower.contains("vinyl") || lower.contains("lp")
                || lower.contains("7\"") || lower.contains("10\"") || lower.contains("12\"")
        }
    }

    /// Scores a candidate against the Discogs side, or returns nil if it's disqualified
    /// (format disagreement when Discogs says vinyl — B2's "must agree" hard constraint).
    static func score(candidate: MBCandidate, discogs: DiscogsSide) -> Double? {
        if isVinylFormat(discogs.formats) {
            guard !candidate.formats.isEmpty, isVinylFormat(candidate.formats) else { return nil }
        }

        let artistScore = discogs.artists
            .map { FuzzyMatch.similarity($0, candidate.artist) }
            .max() ?? 0

        let discogsBase = FuzzyMatch.splitVersion(discogs.title).base
        let candidateBase = FuzzyMatch.splitVersion(candidate.title).base
        let titleScore = FuzzyMatch.similarity(discogsBase, candidateBase)

        var total = artistScore * 0.40 + titleScore * 0.40

        if let discogsYear = discogs.year, let candidateYear = year(from: candidate.date) {
            let diff = abs(discogsYear - candidateYear)
            if diff == 0 {
                total += 0.10
            } else if diff <= MBMatchThresholds.yearToleranceYears {
                total += 0.06
            } else {
                total -= 0.05
            }
        }

        if let discogsCount = discogs.trackCount, let candidateCount = candidate.trackCount, candidateCount > 0 {
            if discogsCount == candidateCount {
                total += 0.05
            } else if abs(discogsCount - candidateCount) > 2 {
                total -= 0.05
            }
        }

        if let discogsCountry = discogs.country, !discogsCountry.isEmpty,
           let candidateCountry = candidate.country,
           discogsCountry.caseInsensitiveCompare(candidateCountry) == .orderedSame {
            total += 0.03
        }

        if let catno = discogs.catalogNumber, !catno.isEmpty,
           candidate.catalogNumbers.contains(where: { normalize(catalogNumber: $0) == normalize(catalogNumber: catno) }) {
            total += 0.07
        }

        return min(max(total, 0), 1)
    }

    private static func year(from dateString: String?) -> Int? {
        guard let dateString, dateString.count >= 4 else { return nil }
        return Int(dateString.prefix(4))
    }

    private static func normalize(catalogNumber: String) -> String {
        catalogNumber.uppercased().replacingOccurrences(of: #"[\s\-]"#, with: "", options: .regularExpression)
    }
}
