import Foundation

struct Track: Codable, Hashable {
    let position: String
    let title: String
    let duration: String
    /// Per-track artist credit, present on compilation tracklists. Nil on normal releases.
    let artists: [ArtistCredit]?
}

extension Track {
    /// Parses "4:32" or "1:04:32" into milliseconds. Nil for "" or anything that
    /// doesn't parse as 2 or 3 colon-separated integers (tolerates junk).
    var durationMs: Int? {
        guard !duration.isEmpty else { return nil }
        let parts = duration.split(separator: ":").map { Int($0) }
        guard parts.allSatisfy({ $0 != nil }), (2...3).contains(parts.count) else { return nil }
        let nums = parts.compactMap { $0 }
        let seconds = nums.count == 3
            ? nums[0] * 3600 + nums[1] * 60 + nums[2]
            : nums[0] * 60 + nums[1]
        return seconds * 1000
    }
}
