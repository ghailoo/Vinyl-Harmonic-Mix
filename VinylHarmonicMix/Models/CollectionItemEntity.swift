import SwiftData
import Foundation

@Model
final class CollectionItemEntity {
    @Attribute(.unique) var instanceId: Int
    var releaseId: Int
    var folderId: Int
    var rating: Int
    var dateAdded: String
    @Relationship(deleteRule: .cascade) var basicInformation: BasicInformationEntity?

    var mbid: String?
    var mbidScanState: String = MBIDScanState.unscanned.rawValue

    var mbidScannedAt: Date?
    var mbidMatchedTitle: String?
    var mbidMatchedArtist: String?
    var mbidMatchMethod: String?
    var mbidReviewCandidatesData: Data?

    var recordingsScanState: String = RecordingsScanState.unscanned.rawValue
    var recordingsScannedAt: Date?
    @Relationship(deleteRule: .cascade, inverse: \TrackEntity.collectionItem)
    var tracks: [TrackEntity] = []

    var scanState: MBIDScanState {
        MBIDScanState(rawValue: mbidScanState) ?? .unscanned
    }

    var reviewCandidates: [MBReviewCandidate] {
        get {
            guard let data = mbidReviewCandidatesData else { return [] }
            return (try? JSONDecoder().decode([MBReviewCandidate].self, from: data)) ?? []
        }
        set {
            mbidReviewCandidatesData = try? JSONEncoder().encode(newValue)
        }
    }

    var recordingsScanStateEnum: RecordingsScanState {
        RecordingsScanState(rawValue: recordingsScanState) ?? .unscanned
    }

    init(instanceId: Int, releaseId: Int, folderId: Int, rating: Int, dateAdded: String) {
        self.instanceId = instanceId
        self.releaseId = releaseId
        self.folderId = folderId
        self.rating = rating
        self.dateAdded = dateAdded
    }
}

extension CollectionItemEntity {
    /// Number of tracks on this release that have both BPM and Camelot key data.
    func harmonicCoverageCount(featuresByMBID: [String: RecordingFeaturesEntity]) -> Int {
        tracks.filter {
            let f = featuresByMBID[$0.recordingMBID]
            return f?.bpm != nil && f?.camelotCode != nil
        }.count
    }

    var trackCount: Int { tracks.count }
}
