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

    var scanState: MBIDScanState {
        MBIDScanState(rawValue: mbidScanState) ?? .unscanned
    }

    init(instanceId: Int, releaseId: Int, folderId: Int, rating: Int, dateAdded: String) {
        self.instanceId = instanceId
        self.releaseId = releaseId
        self.folderId = folderId
        self.rating = rating
        self.dateAdded = dateAdded
    }
}
