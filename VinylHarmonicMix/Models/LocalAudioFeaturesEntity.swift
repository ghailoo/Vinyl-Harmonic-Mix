import SwiftData
import Foundation

@Model
final class LocalAudioFeaturesEntity {
    var rawBpm: Double = 0
    var bpm: Double = 0
    var key: String = ""
    var scale: String = ""
    var keyStrength: Double = 0
    var camelot: String = ""
    var analyzedAt: Date = Date()
    var analyzerVersion: String = ""

    @Relationship(deleteRule: .nullify, inverse: \TrackEntity.localAudioFeatures)
    var track: TrackEntity?

    init() {}
}
