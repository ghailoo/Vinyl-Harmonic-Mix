import SwiftData
import Foundation

@Model
final class CuePointEntity {
    var timeSec: Double = 0.0
    var feature: String = ""
    var novelty: Double = 0.0
    var beatIndex: Int = 0
    var type: String = "switch_in"     // "switch_in" | "structural"
    var energyDirection: String = ""   // "rise" | "fall" | "neutral" | ""
    var energyDelta: Double = 0.0      // abs(mean_after - mean_before), normalised 0..1
    var source: String = "energy"      // "energy" | "kick" | "both" | "manual"
    var isManual: Bool = false
    var createdAt: Date = Date()

    var localFile: LocalFileEntity?

    init() {}
}
