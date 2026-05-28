import SwiftData
import Foundation

@Model
final class LocalFileEntity {
    @Attribute(.unique) var filePath: String
    var fileName: String
    var parentFolder: String = ""      // direct parent folder (may be album or artist)
    var grandparentFolder: String = "" // one level up — artist folder in Artist/Album/Track layouts
    var format: String
    var fileSizeBytes: Int?
    var durationSeconds: Int?
    var durationMs: Int = 0       // populated by AVAsset during indexing; 0 = unknown
    var artistFolder: String = "" // first path component under "Tracks/" root; "" until backfilled
    var fingerprint: String?
    var acoustIDRecordingMBIDs: [String]
    var matchScore: Double?
    var matchMethod: String
    var indexedAt: Date
    var fingerprintedAt: Date?

    // File-level harmonic analysis (populated independently of track matching)
    var rawBpm: Double = 0
    var bpm: Double = 0
    var key: String = ""
    var scale: String = ""
    var keyStrength: Double = 0
    var camelot: String = ""
    var analyzedAt: Date? = nil
    var analyzerVersion: String = ""

    @Relationship(deleteRule: .cascade, inverse: \CuePointEntity.localFile)
    var cuePoints: [CuePointEntity] = []
    var cueAnalyzedAt: Date? = nil
    var cueAnalyzerVersion: String = ""
    var fourToFloor: Bool = false
    var kickRegularity: Double = 0
    var waveformPeaks: Data? = nil   // 4000 × Float32 = 16 KB; nil until first generation

    var track: TrackEntity?

    init(filePath: String, fileName: String,
         parentFolder: String = "", grandparentFolder: String = "",
         format: String, fileSizeBytes: Int?) {
        self.filePath = filePath
        self.fileName = fileName
        self.parentFolder = parentFolder
        self.grandparentFolder = grandparentFolder
        self.format = format
        self.fileSizeBytes = fileSizeBytes
        self.acoustIDRecordingMBIDs = []
        self.matchMethod = "unmatched"
        self.indexedAt = .now
    }
}
