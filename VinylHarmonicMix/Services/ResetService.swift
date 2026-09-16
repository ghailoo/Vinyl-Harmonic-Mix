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
        let stamp = ISO8601DateFormatter().string(from: .now).replacingOccurrences(of: ":", with: "-")
        let folder = backupsRootDirectory.appendingPathComponent("reset-\(stamp)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        try copyStoreFile(to: folder)

        let backup = try MatchesBackupService.collectBackup(modelContext: modelContext)
        try MatchesBackupService.writeBackup(backup, to: folder.appendingPathComponent("matches-backup.json"))

        try deleteAllEntities(modelContext)
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

    /// Deletes children before parents so cascade rules don't race explicit deletes of the
    /// same rows; harmless either way since every type in the schema is wiped regardless.
    private static func deleteAllEntities(_ context: ModelContext) throws {
        try context.delete(model: CuePointEntity.self)
        try context.delete(model: LocalAudioFeaturesEntity.self)
        try context.delete(model: LocalFileEntity.self)
        try context.delete(model: SetlistItemEntity.self)
        try context.delete(model: SetlistEntity.self)
        try context.delete(model: RecordingFeaturesEntity.self)
        try context.delete(model: TrackEntity.self)
        try context.delete(model: ArtistCreditEntity.self)
        try context.delete(model: LabelCreditEntity.self)
        try context.delete(model: FormatEntity.self)
        try context.delete(model: BasicInformationEntity.self)
        try context.delete(model: ReleaseDetailEntity.self)
        try context.delete(model: CollectionItemEntity.self)
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
