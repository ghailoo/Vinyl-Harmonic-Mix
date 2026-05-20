import SwiftData
import Foundation

@Model
final class LocalFileEntity {
    @Attribute(.unique) var filePath: String
    var fileName: String
    var format: String
    var fileSizeBytes: Int?
    var durationSeconds: Int?
    var fingerprint: String?
    var acoustIDRecordingMBIDs: [String]
    var matchScore: Double?
    var matchMethod: String
    var indexedAt: Date
    var fingerprintedAt: Date?

    var track: TrackEntity?

    init(filePath: String, fileName: String, format: String, fileSizeBytes: Int?) {
        self.filePath = filePath
        self.fileName = fileName
        self.format = format
        self.fileSizeBytes = fileSizeBytes
        self.acoustIDRecordingMBIDs = []
        self.matchMethod = "unmatched"
        self.indexedAt = .now
    }
}
