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

// MARK: - Restore result

struct RestoreResult {
    let restored: Int
    let skippedAlreadyMatched: Int
    let skippedFileMissing: Int
    let skippedTrackMissing: Int
    let totalInBackup: Int
}

// MARK: - Import / restore

extension MatchesBackupService {

    /// Reads and parses a backup JSON file. Throws on parse failure or unsupported schema version.
    static func readBackup(from url: URL) throws -> MatchesBackup {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let backup = try decoder.decode(MatchesBackup.self, from: data)
        guard backup.schemaVersion == 1 else {
            throw NSError(domain: "MatchesBackupService", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Unsupported backup schema version \(backup.schemaVersion). Expected version 1."
            ])
        }
        return backup
    }

    /// Applies a backup to the current SwiftData store using an additive-only policy:
    /// - TrackEntity already confident → skipped (preserve user intent)
    /// - LocalFileEntity not found by fileName → skipped (file missing from library)
    /// - TrackEntity not found by (instanceId, position) → skipped (library changed)
    /// - All others → match written
    static func applyBackup(_ backup: MatchesBackup, modelContext: ModelContext) throws -> RestoreResult {
        var restored = 0
        var skippedAlreadyMatched = 0
        var skippedFileMissing = 0
        var skippedTrackMissing = 0

        for entry in backup.entries {
            let instanceId = entry.instanceId
            let position = entry.position

            let collectionItemDescriptor = FetchDescriptor<CollectionItemEntity>(
                predicate: #Predicate { $0.instanceId == instanceId }
            )
            guard let collectionItem = try modelContext.fetch(collectionItemDescriptor).first else {
                skippedTrackMissing += 1
                continue
            }
            guard let track = collectionItem.tracks.first(where: { $0.position == position }) else {
                skippedTrackMissing += 1
                continue
            }

            if track.fileMatchState == "confident" {
                skippedAlreadyMatched += 1
                continue
            }

            let targetFileName = entry.fileName
            let fileDescriptor = FetchDescriptor<LocalFileEntity>(
                predicate: #Predicate { $0.fileName == targetFileName }
            )
            let candidates = try modelContext.fetch(fileDescriptor)

            guard !candidates.isEmpty else {
                skippedFileMissing += 1
                continue
            }

            let localFile: LocalFileEntity
            if candidates.count == 1 {
                localFile = candidates[0]
            } else if let unmatched = candidates.first(where: { $0.track == nil }) {
                localFile = unmatched
            } else {
                print("[RESTORE] Skipping ambiguous filename: \(targetFileName) (\(candidates.count) candidates, all already matched)")
                skippedFileMissing += 1
                continue
            }

            localFile.track = track
            localFile.matchMethod = entry.matchMethod
            localFile.matchScore = entry.matchScore
            track.fileMatchState = "confident"
            track.primaryLocalFilePath = localFile.filePath

            restored += 1
        }

        try modelContext.save()

        return RestoreResult(
            restored: restored,
            skippedAlreadyMatched: skippedAlreadyMatched,
            skippedFileMissing: skippedFileMissing,
            skippedTrackMissing: skippedTrackMissing,
            totalInBackup: backup.totalEntries
        )
    }

    /// Resolves the stored security-scoped bookmark to a URL.
    /// Returns nil if no bookmark stored, resolution fails, or file no longer exists.
    static func storedBackupURL() -> URL? {
        guard let bookmark = UserDefaults.standard.data(forKey: UserDefaults.matchesBackupBookmarkKey) else {
            return nil
        }
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmark,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            return nil
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        return url
    }
}
