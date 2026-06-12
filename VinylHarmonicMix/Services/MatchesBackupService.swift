import Foundation
import SwiftData

// MARK: - UserDefaults keys

extension UserDefaults {
    /// Security-scoped bookmark Data for the user's chosen matches backup file location.
    /// Set after the first successful export. Used by Phase 2 (launch detection) and Phase 3 (auto-update).
    static let matchesBackupBookmarkKey = "VinylHarmonicMix.MatchesBackupBookmark"
}

// MARK: - JSON schema

/// A single confident-match record in the backup JSON.
/// Keyed on (instanceId, position, fileName) — NOT absolute filePath — for portability
/// across library re-mounts (e.g., NAS path changes from /Volumes/Music to /Volumes/Music-2).
struct MatchBackupEntry: Codable {
    let instanceId: Int       // Discogs CollectionItemEntity.instanceId
    let position: String      // TrackEntity.position — which track on the release
    let fileName: String      // Just the filename; used to re-locate file on restore
    let matchMethod: String   // "string" | "manual" | "fingerprint"
    let matchScore: Double?
    let recordingMBID: String // For integrity verification on restore
    let exportedAt: Date
}

/// Top-level JSON envelope. schemaVersion allows future evolution without breaking old backups.
struct MatchesBackup: Codable {
    let schemaVersion: Int    // Currently 1
    let exportedAt: Date
    let totalEntries: Int
    let entries: [MatchBackupEntry]
}

// MARK: - Service

@MainActor
final class MatchesBackupService {

    /// Collects all confident matches from the current SwiftData store.
    /// A "confident" match requires: fileMatchState == "confident", non-empty primaryLocalFilePath,
    /// a matching LocalFileEntity, and a parent CollectionItemEntity.
    static func collectBackup(modelContext: ModelContext) throws -> MatchesBackup {
        var descriptor = FetchDescriptor<TrackEntity>(
            predicate: #Predicate { $0.fileMatchState == "confident" }
        )
        descriptor.relationshipKeyPathsForPrefetching = [
            \TrackEntity.localFiles,
            \TrackEntity.collectionItem
        ]
        let confidentTracks = try modelContext.fetch(descriptor)

        var entries: [MatchBackupEntry] = []
        let now = Date()

        for track in confidentTracks {
            guard let filePath = track.primaryLocalFilePath, !filePath.isEmpty else { continue }
            guard let collectionItem = track.collectionItem else { continue }
            guard let localFile = track.localFiles.first(where: { $0.filePath == filePath }) else { continue }

            let fileName = (filePath as NSString).lastPathComponent

            entries.append(MatchBackupEntry(
                instanceId: collectionItem.instanceId,
                position: track.position,
                fileName: fileName,
                matchMethod: localFile.matchMethod,
                matchScore: localFile.matchScore,
                recordingMBID: track.recordingMBID,
                exportedAt: now
            ))
        }

        return MatchesBackup(
            schemaVersion: 1,
            exportedAt: now,
            totalEntries: entries.count,
            entries: entries
        )
    }

    /// Serializes the backup envelope to pretty-printed JSON and writes it atomically to the given URL.
    static func writeBackup(_ backup: MatchesBackup, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(backup)
        try data.write(to: url, options: .atomic)
    }
}
