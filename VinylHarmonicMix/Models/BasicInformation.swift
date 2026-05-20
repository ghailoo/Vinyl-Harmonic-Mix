import Foundation

struct BasicInformation: Codable, Hashable {
    let title: String
    let year: Int
    let coverImage: String
    let thumb: String
    let artists: [ArtistCredit]
    let labels: [LabelCredit]
    let formats: [Format]
    let genres: [String]
    let styles: [String]

    enum CodingKeys: String, CodingKey {
        case title, year, thumb, artists, labels, formats, genres, styles
        case coverImage = "cover_image"
    }
}
