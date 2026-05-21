import SwiftData
import Foundation

@Model
final class TrackEntity {
    @Attribute(.unique) var trackMBID: String
    var recordingMBID: String
    var position: String
    var title: String
    var durationMs: Int?
    var artistCredit: String
    var fetchedAt: Date

    var collectionItem: CollectionItemEntity?

    @Relationship(deleteRule: .nullify, inverse: \LocalFileEntity.track)
    var localFiles: [LocalFileEntity] = []

    var fileMatchState: String = "unscanned"
    var primaryLocalFilePath: String? = nil
    // Top-N candidate file paths from the last scan — persists across app restarts so
    // review rows can show their best guess without re-running the scan.
    var candidateFilePaths: [String] = []

    init(trackMBID: String, recordingMBID: String, position: String, title: String,
         durationMs: Int?, artistCredit: String) {
        self.trackMBID = trackMBID
        self.recordingMBID = recordingMBID
        self.position = position
        self.title = title
        self.durationMs = durationMs
        self.artistCredit = artistCredit
        self.fetchedAt = .now
    }
}
