import Foundation
import SwiftData

/// "Reset All Data" — wipes every imported record and starts from zero, after taking a
/// safety copy of the live store + a matches backup. Never deletes prior backup folders.
@MainActor
enum ResetService {
    struct Summary {
        let backupFolder: URL
        let matchesBackedUp: Int
    }

    /// Thrown only once the safety backup is already written to disk, so callers can tell
    /// the user their data is untouched and exactly where the backup lives.
    enum ResetError: LocalizedError {
        case deletionFailed(backupFolder: URL, underlying: Error)

        var errorDescription: String? {
            switch self {
            case .deletionFailed(let backupFolder, let underlying):
                return "Nothing was deleted — the reset failed partway through, but your data is untouched. A safety backup was already saved to:\n\(backupFolder.path)\n\nError: \(underlying.localizedDescription)"
            }
        }
    }

    static var backupsRootDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/VinylHarmonicMix/Backups")
    }

    /// Most recent "reset-*" backup folder, if any. Folder names are ISO8601 timestamps
    /// (colons replaced with "-"), so a lexical sort is also a chronological sort.
    static func mostRecentBackup() -> (url: URL, date: Date)? {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: backupsRootDirectory,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        guard let latest = entries
            .filter({ $0.lastPathComponent.hasPrefix("reset-") })
            .sorted(by: { $0.lastPathComponent > $1.lastPathComponent })
            .first
        else { return nil }

        let date = (try? latest.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .now
        return (latest, date)
    }

    /// Copies the live store + a matches backup to a fresh timestamped folder, deletes every
    /// SwiftData entity, and clears UserDefaults except the keys needed to keep the user's
    /// Discogs/AcoustID credentials and library folder selection intact.
    static func performReset(modelContext: ModelContext) throws -> Summary {
        // Fractional seconds so two resets within the same second (e.g. an immediate retry
        // after a failure) still land in distinct folders instead of overwriting one another.
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let stamp = formatter.string(from: .now).replacingOccurrences(of: ":", with: "-")
        let folder = backupsRootDirectory.appendingPathComponent("reset-\(stamp)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        try copyStoreFile(to: folder)

        let backup = try MatchesBackupService.collectBackup(modelContext: modelContext)
        try MatchesBackupService.writeBackup(backup, to: folder.appendingPathComponent("matches-backup.json"))

        // From here on the backup is safely on disk — a failure below must tell the caller
        // that data is intact rather than reporting a generic error.
        do {
            try deleteAllEntities(modelContext)
        } catch {
            throw ResetError.deletionFailed(backupFolder: folder, underlying: error)
        }

        clearUserDefaults()

        return Summary(backupFolder: folder, matchesBackedUp: backup.totalEntries)
    }

    /// Copies the store file plus its WAL/SHM sidecars (if present) — a SQLite store's
    /// most recent writes can live in the WAL file, so skipping it risks an incomplete copy.
    private static func copyStoreFile(to folder: URL) throws {
        let storePath = VinylHarmonicMixApp.storeURL().path
        for suffix in ["", "-wal", "-shm"] {
            let source = URL(fileURLWithPath: storePath + suffix)
            guard FileManager.default.fileExists(atPath: source.path) else { continue }
            try FileManager.default.copyItem(at: source, to: folder.appendingPathComponent(source.lastPathComponent))
        }
    }

    /// SwiftData's batch `context.delete(model:)` can't evaluate relationship rules and trips
    /// a "mandatory nullify inverse" constraint trigger the moment a cascade/nullify rule is
    /// involved (e.g. LocalFileEntity.cuePoints → CuePointEntity.localFile). Object-level
    /// deletes honour those rules, so fetch every row of a type and delete it individually.
    private static func deleteAll<T: PersistentModel>(_ type: T.Type, in context: ModelContext) throws {
        for object in try context.fetch(FetchDescriptor<T>()) {
            context.delete(object)
        }
    }

    /// Delete the three cascade roots first — CollectionItemEntity cascades to
    /// BasicInformationEntity (→ artists/labels/formats) and TrackEntity; LocalFileEntity
    /// cascades to CuePointEntity; SetlistEntity cascades to SetlistItemEntity (see the
    /// @Relationship(deleteRule:) declarations in Models/*.swift). Whatever those cascades
    /// don't reach (orphan rows with no parent) is cleaned up explicitly afterwards, in any
    /// order, then a single save commits everything atomically.
    private static func deleteAllEntities(_ context: ModelContext) throws {
        try deleteAll(CollectionItemEntity.self, in: context)
        try deleteAll(LocalFileEntity.self, in: context)
        try deleteAll(SetlistEntity.self, in: context)

        try deleteAll(TrackEntity.self, in: context)
        try deleteAll(BasicInformationEntity.self, in: context)
        try deleteAll(ArtistCreditEntity.self, in: context)
        try deleteAll(LabelCreditEntity.self, in: context)
        try deleteAll(FormatEntity.self, in: context)
        try deleteAll(ReleaseDetailEntity.self, in: context)
        try deleteAll(RecordingFeaturesEntity.self, in: context)
        try deleteAll(LocalAudioFeaturesEntity.self, in: context)
        try deleteAll(CuePointEntity.self, in: context)
        try deleteAll(SetlistItemEntity.self, in: context)

        try context.save()
    }

    /// Discogs token/username and the AcoustID key live in the Keychain, not UserDefaults,
    /// so they survive automatically. Only the library folder bookmark + display path need
    /// an explicit allow-list entry here.
    private static func clearUserDefaults() {
        let preserve: Set<String> = [LocalLibraryService.bookmarkKey, LocalLibraryService.displayPathKey]
        guard let bundleID = Bundle.main.bundleIdentifier,
              let domain = UserDefaults.standard.persistentDomain(forName: bundleID) else { return }
        for key in domain.keys where !preserve.contains(key) {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}
