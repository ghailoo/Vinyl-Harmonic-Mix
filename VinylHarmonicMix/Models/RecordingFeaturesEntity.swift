import SwiftData
import Foundation

@Model
final class RecordingFeaturesEntity {
    @Attribute(.unique) var recordingMBID: String

    // Rhythm
    var bpm: Double?
    var danceabilityValue: Double?

    // Tonal
    var keyNote: String?
    var keyScale: String?
    var keyConfidence: Double?
    var camelotCode: String?

    // Highlevel classifiers
    var moodHappy: String?
    var moodPartyProb: Double?
    var moodElectronicProb: Double?
    var moodAcousticProb: Double?
    var danceabilityLabel: String?
    var danceabilityProb: Double?
    var genreDortmund: String?

    var fetchedAt: Date

    init(recordingMBID: String) {
        self.recordingMBID = recordingMBID
        self.fetchedAt = .now
    }
}
