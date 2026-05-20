import SwiftData

@Model
final class ArtistCreditEntity {
    var artistId: Int
    var name: String

    init(artistId: Int, name: String) {
        self.artistId = artistId
        self.name = name
    }
}
