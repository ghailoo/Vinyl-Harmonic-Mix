import SwiftData

@Model
final class BasicInformationEntity {
    var title: String
    var year: Int
    var coverImage: String
    var thumb: String
    var genres: [String]
    var styles: [String]
    @Relationship(deleteRule: .cascade) var artists: [ArtistCreditEntity]
    @Relationship(deleteRule: .cascade) var labels: [LabelCreditEntity]
    @Relationship(deleteRule: .cascade) var formats: [FormatEntity]

    init(title: String, year: Int, coverImage: String, thumb: String,
         genres: [String], styles: [String]) {
        self.title = title
        self.year = year
        self.coverImage = coverImage
        self.thumb = thumb
        self.genres = genres
        self.styles = styles
        self.artists = []
        self.labels = []
        self.formats = []
    }
}
