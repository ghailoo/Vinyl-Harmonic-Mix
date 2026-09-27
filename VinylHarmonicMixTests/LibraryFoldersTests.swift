//
//  LibraryFoldersTests.swift
//  VinylHarmonicMixTests
//
//  Multiple library folders: kind ranking boost, overlap rejection, legacy migration,
//  and the safety rule — an unreachable folder's rows and matches survive an orphan sweep.
//  Every test uses its own UserDefaults suite, never the app's real defaults.
//

import Testing
import Foundation
import SwiftData
@testable import VinylHarmonicMix

@MainActor
struct LibraryFoldersTests {

    // MARK: - Helpers

    private static func makeDefaults() -> UserDefaults {
        let name = "LibraryFoldersTests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    private static func makeTempDir(withFile: Bool = true) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibraryFoldersTests-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        if withFile { try Data().write(to: url.appendingPathComponent("a.flac")) }
        return url
    }

    private static func makeContext() throws -> ModelContext {
        let container = try ModelContainer(for: LocalFileEntity.self, TrackEntity.self,
                                           configurations: .init(isStoredInMemoryOnly: true))
        return ModelContext(container)
    }

    /// FileMatchCoordinator.init clears this flag in UserDefaults.standard (the app's real
    /// defaults, since the app hosts the tests); put it back afterwards.
    private static func makeCoordinator(context: ModelContext, defaults: UserDefaults) -> FileMatchCoordinator {
        let key = "VinylHarmonicMix.PendingWaveformGenerationPaused"
        let saved = UserDefaults.standard.object(forKey: key)
        let coordinator = FileMatchCoordinator(context: context, driveMonitor: DriveMonitor(defaults: defaults))
        UserDefaults.standard.set(saved, forKey: key)
        return coordinator
    }

    @discardableResult
    private static func insertFile(_ path: String, folder: LibraryFolder?, in context: ModelContext) -> LocalFileEntity {
        let file = LocalFileEntity(filePath: path, fileName: (path as NSString).lastPathComponent,
                                   format: "flac", fileSizeBytes: nil)
        file.libraryFolderID = folder?.id.uuidString ?? ""
        context.insert(file)
        return file
    }

    private static func insertConfidentTrack(path: String, in context: ModelContext) -> TrackEntity {
        let track = TrackEntity(trackMBID: UUID().uuidString, recordingMBID: UUID().uuidString,
                                position: "1", title: "T", durationMs: 0, artistCredit: "A")
        track.fileMatchState = "confident"
        track.primaryLocalFilePath = path
        context.insert(track)
        return track
    }

    private static func rowExists(_ path: String, in context: ModelContext) throws -> Bool {
        try context.fetchCount(FetchDescriptor<LocalFileEntity>(predicate: #Predicate { $0.filePath == path })) == 1
    }

    // MARK: - C2: folder-kind ranking boost

    @Test func kindBoostFavoursMatchingFolderKind() {
        let w = ScoredCandidate.folderKindBoostWeight
        #expect(FileMatchCoordinator.folderKindBoost(isCompilation: true, kind: .compilations) == w)
        #expect(FileMatchCoordinator.folderKindBoost(isCompilation: false, kind: .albums) == w)
        #expect(FileMatchCoordinator.folderKindBoost(isCompilation: false, kind: .singles) == w)
        #expect(FileMatchCoordinator.folderKindBoost(isCompilation: true, kind: .albums) == 0)
        #expect(FileMatchCoordinator.folderKindBoost(isCompilation: false, kind: .compilations) == 0)
        #expect(FileMatchCoordinator.folderKindBoost(isCompilation: true, kind: .other) == 0)
        #expect(FileMatchCoordinator.folderKindBoost(isCompilation: false, kind: nil) == 0)
    }

    @Test func kindBoostBreaksTiesButIsNotAFilter() {
        func candidate(_ path: String, title: Double, boost: Double) -> ScoredCandidate {
            ScoredCandidate(fileID: nil, filePath: path, fileName: path, format: "flac",
                            artistScore: 1, titleScore: title, versionScore: 1, version: nil,
                            kindBoost: boost)
        }
        let w = ScoredCandidate.folderKindBoostWeight

        // Equal scores: the right-kind folder wins.
        let tie = FileMatchCoordinator.sortCandidates([candidate("/wrong", title: 0.9, boost: 0),
                                                       candidate("/right", title: 0.9, boost: w)])
        #expect(tie.first?.filePath == "/right")

        // A wrong-kind file that scores clearly better still wins — nothing is filtered out.
        let clear = FileMatchCoordinator.sortCandidates([candidate("/right", title: 0.6, boost: w),
                                                         candidate("/wrong", title: 1.0, boost: 0)])
        #expect(clear.map(\.filePath) == ["/wrong", "/right"])

        // The boost never leaks into combinedScore (what gets stored and tiered).
        #expect(candidate("/x", title: 0.9, boost: w).combinedScore == candidate("/x", title: 0.9, boost: 0).combinedScore)
    }

    // MARK: - A3: nested / duplicate folder rejection

    @Test func addFolderRejectsSameNestedAndParent() throws {
        let defaults = Self.makeDefaults()
        let parent = try Self.makeTempDir()
        let root = parent.appendingPathComponent("Music", isDirectory: true)
        let sub = root.appendingPathComponent("Albums", isDirectory: true)
        let sibling = parent.appendingPathComponent("MusicExtra", isDirectory: true)
        for dir in [sub, sibling] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        defer { try? FileManager.default.removeItem(at: parent) }

        try LocalLibraryService.addFolder(root, kind: .albums, defaults: defaults)

        // Same, nested inside, containing, and same-but-different-case (APFS/SMB are case-insensitive).
        for clash in [root, sub, parent, URL(fileURLWithPath: root.path.uppercased())] {
            #expect(throws: LocalLibraryService.FolderError.self) {
                try LocalLibraryService.addFolder(clash, kind: .singles, defaults: defaults)
            }
        }
        // A sibling that merely shares a name prefix ("Music" / "MusicExtra") is fine.
        try LocalLibraryService.addFolder(sibling, kind: .singles, defaults: defaults)
        #expect(LocalLibraryService.folders(defaults: defaults).map(\.displayPath) == [root.path, sibling.path])
    }

    // MARK: - A2: migration from the single legacy bookmark

    @Test func migratesLegacyBookmarkAndMatchesStillResolve() async throws {
        let defaults = Self.makeDefaults()
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let legacy = try dir.bookmarkData()
        defaults.set(legacy, forKey: LocalLibraryService.bookmarkKey)
        defaults.set(dir.path, forKey: LocalLibraryService.displayPathKey)

        let migrated = LocalLibraryService.folders(defaults: defaults)
        #expect(migrated.count == 1)
        let folder = try #require(migrated.first)
        #expect(folder.kind == .other)
        #expect(folder.bookmark == legacy)
        #expect(folder.displayPath == dir.path)
        // Legacy keys untouched (rollback to v2.1-pre-multifolder keeps working); no re-migration.
        #expect(defaults.data(forKey: LocalLibraryService.bookmarkKey) == legacy)
        #expect(defaults.string(forKey: LocalLibraryService.displayPathKey) == dir.path)
        #expect(LocalLibraryService.folders(defaults: defaults).map(\.id) == [folder.id])
        #expect(LocalLibraryService.resolve(folder, defaults: defaults) != nil)

        // Pre-multifolder rows (no folder ID) get stamped with entry #1, and their confident
        // match survives a sweep of that folder.
        let context = try Self.makeContext()
        let path = dir.appendingPathComponent("a.flac").path
        let file = Self.insertFile(path, folder: nil, in: context)
        let track = Self.insertConfidentTrack(path: path, in: context)
        try context.save()

        let coordinator = Self.makeCoordinator(context: context, defaults: defaults)
        coordinator.assignLibraryFolderIDs()
        #expect(file.libraryFolderID == folder.id.uuidString)

        await coordinator.runOrphanSweep(over: [folder])
        #expect(try Self.rowExists(path, in: context))
        #expect(track.fileMatchState == "confident")
        #expect(track.primaryLocalFilePath == path)
    }

    // MARK: - SAFETY: unreachable folder survives the orphan sweep

    @Test func unreachableFolderSurvivesSweepWhileReachableFolderIsSwept() async throws {
        let dirA = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dirA) }
        // Folder B: e.g. NAS asleep — nothing under it exists on disk right now.
        let pathB = "/Volumes/LibraryFoldersTests-\(UUID().uuidString)/Music"
        let folderA = LibraryFolder(id: UUID(), bookmark: Data(), displayPath: dirA.path, kind: .albums)
        let folderB = LibraryFolder(id: UUID(), bookmark: Data(), displayPath: pathB, kind: .compilations)

        let context = try Self.makeContext()
        // A: present+matched (keep), missing+matched (Case B), missing+unlinked (Case A).
        let aPresent = dirA.appendingPathComponent("a.flac").path
        let aGoneMatched = dirA.appendingPathComponent("gone-matched.flac").path
        let aGoneUnlinked = dirA.appendingPathComponent("gone-unlinked.flac").path
        Self.insertFile(aPresent, folder: folderA, in: context)
        Self.insertFile(aGoneMatched, folder: folderA, in: context)
        Self.insertFile(aGoneUnlinked, folder: folderA, in: context)
        let aPresentTrack = Self.insertConfidentTrack(path: aPresent, in: context)
        let aGoneTrack = Self.insertConfidentTrack(path: aGoneMatched, in: context)
        // B: every file reads as missing because the folder is unreachable.
        let bMatched = pathB + "/Various/x.flac"
        let bUnlinked = pathB + "/Various/y.flac"
        Self.insertFile(bMatched, folder: folderB, in: context)
        Self.insertFile(bUnlinked, folder: folderB, in: context)
        let bTrack = Self.insertConfidentTrack(path: bMatched, in: context)
        // No folder ID (removed folder / manual pick) under A's path: never swept.
        let noID = dirA.appendingPathComponent("no-id.flac").path
        Self.insertFile(noID, folder: nil, in: context)
        // Stamped with A's ID but path under B: ID and path disagree → not swept.
        let mislabeled = pathB + "/mislabeled.flac"
        Self.insertFile(mislabeled, folder: folderA, in: context)
        try context.save()

        let coordinator = Self.makeCoordinator(context: context, defaults: Self.makeDefaults())
        await coordinator.runOrphanSweep(over: [folderA])   // B not verified reachable

        // Reachable folder A: the sweep still works.
        #expect(try Self.rowExists(aPresent, in: context))
        #expect(aPresentTrack.fileMatchState == "confident")
        #expect(try !Self.rowExists(aGoneMatched, in: context))
        #expect(aGoneTrack.fileMatchState == "noMatch")
        #expect(aGoneTrack.primaryLocalFilePath == nil)
        #expect(try !Self.rowExists(aGoneUnlinked, in: context))

        // Unreachable folder B: every row and match untouched.
        #expect(try Self.rowExists(bMatched, in: context))
        #expect(try Self.rowExists(bUnlinked, in: context))
        #expect(bTrack.fileMatchState == "confident")
        #expect(bTrack.primaryLocalFilePath == bMatched)
        #expect(try Self.rowExists(noID, in: context))
        #expect(try Self.rowExists(mislabeled, in: context))

        // Nothing verified reachable → nothing swept at all.
        await coordinator.runOrphanSweep(over: [])
        #expect(try Self.rowExists(bMatched, in: context))
        #expect(bTrack.fileMatchState == "confident")
    }

    // MARK: - B2: deep reachability check

    @Test func deepAccessCheck() throws {
        let full = try Self.makeTempDir()
        let empty = try Self.makeTempDir(withFile: false)
        defer { for d in [full, empty] { try? FileManager.default.removeItem(at: d) } }

        #expect(DriveMonitor.isDeepAccessible(url: full, expectedPath: full.path))
        #expect(!DriveMonitor.isDeepAccessible(url: empty, expectedPath: empty.path))       // ghost mount
        #expect(!DriveMonitor.isDeepAccessible(url: full, expectedPath: full.path + "-1"))  // remounted elsewhere
        let missing = URL(fileURLWithPath: "/Volumes/LibraryFoldersTests-\(UUID().uuidString)")
        #expect(!DriveMonitor.isDeepAccessible(url: missing, expectedPath: missing.path))
    }
}
