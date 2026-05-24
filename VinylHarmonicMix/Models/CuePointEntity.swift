import SwiftData
import Foundation

@Model
final class CuePointEntity {
    var timeSec: Double = 0.0
    var feature: String = ""
    var novelty: Double = 0.0
    var beatIndex: Int = 0
    var createdAt: Date = Date()

    var localFile: LocalFileEntity?

    init() {}
}
