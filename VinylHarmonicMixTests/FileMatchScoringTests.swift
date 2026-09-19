//
//  FileMatchScoringTests.swift
//  VinylHarmonicMixTests
//
//  Pure-function tests for Part C: rehydrated candidate scores must match what a live
//  scan would compute for the same track/file pair.
//

import Testing
import SwiftData
@testable import VinylHarmonicMix

@MainActor
struct FileMatchScoringTests {

    // FileSummary.id is a real PersistentIdentifier, not a value type tests can synthesize —
    // insert into an in-memory container to get one, mirroring how the live scan obtains it.
    private static func makeFileSummary(fileName: String, artistFolder: String) throws -> FileMatchCoordinator.FileSummary {
        let container = try ModelContainer(for: LocalFileEntity.self, TrackEntity.self,
                                           configurations: .init(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let entity = LocalFileEntity(filePath: "/x/\(fileName)", fileName: fileName, format: "flac", fileSizeBytes: nil)
        entity.artistFolder = artistFolder
        context.insert(entity)
        return FileMatchCoordinator.FileSummary(id: entity.persistentModelID, filePath: entity.filePath,
                                                fileName: entity.fileName, parentFolder: "", grandparentFolder: "",
                                                format: entity.format, durationMs: 0, artistFolder: artistFolder)
    }

    @Test func stemAndVersionSplitsTrailingMixSuffix() {
        let (tokens, version) = FileMatchCoordinator.stemAndVersion(fileName: "01. Artist - Keep On Movin (Club Mix).flac")
        #expect(tokens == ["keep", "on", "movin"])
        #expect(version == "club mix")
    }

    @Test func scoreFileMatchesSameMixHigh() throws {
        let file = try Self.makeFileSummary(fileName: "Keep On Movin (Club Mix).flac", artistFolder: "Soul II Soul")
        let (stemTokens, version) = FileMatchCoordinator.stemAndVersion(fileName: file.fileName)
        let candidate = FileMatchCoordinator.scoreFile(
            file, stemTokens: stemTokens, version: version,
            trackTitleTokens: ["keep", "on", "movin"], trackVersion: "club mix",
            trackDurationMs: 0, artistScore: 1.0
        )
        #expect(candidate != nil)
        #expect(candidate!.titleScore == 1.0)
        #expect(candidate!.versionScore == 1.0)
    }

    @Test func scoreFileRejectsBelowTitleFloor() throws {
        let file = try Self.makeFileSummary(fileName: "Totally Different Song.flac", artistFolder: "Soul II Soul")
        let (stemTokens, version) = FileMatchCoordinator.stemAndVersion(fileName: file.fileName)
        let candidate = FileMatchCoordinator.scoreFile(
            file, stemTokens: stemTokens, version: version,
            trackTitleTokens: ["keep", "on", "movin"], trackVersion: nil,
            trackDurationMs: 0, artistScore: 1.0
        )
        #expect(candidate == nil)
    }

    @Test func artistFolderScoreMatchesFullNameAndSubset() {
        #expect(FileMatchCoordinator.artistFolderScore(trackArtist: "Soul II Soul", folderName: "Soul II Soul") == 1.0)
        #expect(FileMatchCoordinator.artistFolderScore(trackArtist: "D-Mob & Cathy Dennis", folderName: "Cathy Dennis") > 0)
        #expect(FileMatchCoordinator.artistFolderScore(trackArtist: "Soul II Soul", folderName: "Completely Unrelated") == 0)
    }

    @Test func sortCandidatesRanksHigherCombinedScoreFirst() {
        let low = ScoredCandidate(fileID: nil, filePath: "/a", fileName: "a", format: "mp3",
                                  artistScore: 0.5, titleScore: 0.5, versionScore: 0.5, version: nil)
        let high = ScoredCandidate(fileID: nil, filePath: "/b", fileName: "b", format: "flac",
                                   artistScore: 1.0, titleScore: 1.0, versionScore: 1.0, version: nil)
        let sorted = FileMatchCoordinator.sortCandidates([low, high])
        #expect(sorted.first?.filePath == "/b")
    }
}
