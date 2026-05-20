import SwiftData
import Foundation

@Model
final class ReleaseDetailEntity {
    @Attribute(.unique) var releaseId: Int
    var jsonData: Data
    var fetchedAt: Date

    init(releaseId: Int, jsonData: Data, fetchedAt: Date = .now) {
        self.releaseId = releaseId
        self.jsonData = jsonData
        self.fetchedAt = fetchedAt
    }
}
