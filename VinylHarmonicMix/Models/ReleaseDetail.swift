import Foundation

nonisolated struct DiscogsImage: Codable, Hashable {
    let uri: String
    let uri150: String?
    let type: String?
}

nonisolated struct ReleaseDetail: Codable, Hashable {
    let id: Int
    let title: String
    let year: Int?
    let country: String?
    let released: String?
    let barcode: String?
    let artists: [ArtistCredit]?
    let labels: [LabelCredit]?
    let formats: [Format]?
    let genres: [String]?
    let styles: [String]?
    let tracklist: [Track]
    let extraartists: [Credit]?
    let identifiers: [Identifier]?
    let notes: String?
    let masterId: Int?
    let masterUrl: String?
    let dataQuality: String?
    let images: [DiscogsImage]?

    enum CodingKeys: String, CodingKey {
        case id, title, year, country, released, barcode
        case artists, labels, formats, genres, styles, tracklist
        case extraartists, identifiers, notes, images
        case masterId = "master_id"
        case masterUrl = "master_url"
        case dataQuality = "data_quality"
    }
}
