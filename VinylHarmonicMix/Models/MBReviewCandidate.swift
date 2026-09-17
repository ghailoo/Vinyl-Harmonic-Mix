import Foundation

/// One of the top-3 MusicBrainz candidates stored on a `.needsReview` item (B3).
struct MBReviewCandidate: Codable, Identifiable, Hashable {
    var id: String { mbid }
    let mbid: String
    let title: String
    let artist: String
    let format: String
    let country: String
    let date: String
    let catno: String
    let score: Double
}
