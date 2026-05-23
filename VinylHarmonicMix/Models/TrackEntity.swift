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

    var localAudioFeatures: LocalAudioFeaturesEntity?

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

    // MARK: - Effective feature accessors (local > AcousticBrainz)

    enum FeatureSource: String {
        case local, ab, none
    }

    var featureSource: FeatureSource {
        if localAudioFeatures != nil { return .local }
        if let path = primaryLocalFilePath,
           let file = localFiles.first(where: { $0.filePath == path }),
           file.bpm > 0 { return .local }
        if !recordingMBID.isEmpty { return .ab }
        return .none
    }

    var effectiveBpm: Double? {
        if let f = localAudioFeatures, f.bpm > 0 { return f.bpm }
        if let path = primaryLocalFilePath,
           let file = localFiles.first(where: { $0.filePath == path }),
           file.bpm > 0 { return file.bpm }
        return nil
    }

    var effectiveCamelot: String? {
        if let f = localAudioFeatures, !f.camelot.isEmpty { return f.camelot }
        if let path = primaryLocalFilePath,
           let file = localFiles.first(where: { $0.filePath == path }),
           !file.camelot.isEmpty { return file.camelot }
        return nil
    }

    var effectiveKey: String? {
        if let f = localAudioFeatures, !f.key.isEmpty { return "\(f.key) \(f.scale)" }
        if let path = primaryLocalFilePath,
           let file = localFiles.first(where: { $0.filePath == path }),
           !file.key.isEmpty { return "\(file.key) \(file.scale)" }
        return nil
    }
}
