import Foundation

struct MixTrack: Identifiable, Equatable, Hashable, Sendable {
    let displayArtist: String
    let displayTitle: String
    let bpm: Double
    let camelot: String
    let key: String
    let source: TrackEntity.FeatureSource
    let filePath: String?
    let label: String
    let year: Int

    var id: String { filePath ?? "\(displayArtist)|\(displayTitle)|\(bpm)" }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: MixTrack, rhs: MixTrack) -> Bool { lhs.id == rhs.id }

    var camelotSortKey: Int {
        guard let last = camelot.last, let num = Int(camelot.dropLast()) else { return Int.max }
        return (num - 1) * 2 + (last == "B" ? 1 : 0)
    }
}
