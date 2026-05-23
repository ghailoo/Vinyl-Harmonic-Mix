import SwiftData
import Foundation

@Model
final class SetlistItemEntity {
    var position: Int
    var filePath: String
    var displayArtist: String
    var displayTitle: String
    var bpm: Double
    var camelot: String
    var key: String
    var addedAt: Date
    var setlist: SetlistEntity?

    init(position: Int, filePath: String, displayArtist: String, displayTitle: String,
         bpm: Double, camelot: String, key: String) {
        self.position = position
        self.filePath = filePath
        self.displayArtist = displayArtist
        self.displayTitle = displayTitle
        self.bpm = bpm
        self.camelot = camelot
        self.key = key
        self.addedAt = .now
    }
}
