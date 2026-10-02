//
//  RecordingsScanCoordinatorTests.swift
//  VinylHarmonicMixTests
//
//  Part A5: Discogs-as-default-track-source. Covers duration parsing, compilation vs.
//  normal-release artist credit, heading-row skipping, idempotency, and the hard
//  constraint that a release with existing (MusicBrainz-derived) tracks is untouched.
//

import Testing
import SwiftData
import Foundation
@testable import VinylHarmonicMix

@MainActor
struct RecordingsScanCoordinatorTests {

    private static func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: CollectionItemEntity.self, BasicInformationEntity.self, ArtistCreditEntity.self,
                 LabelCreditEntity.self, FormatEntity.self, ReleaseDetailEntity.self, TrackEntity.self,
                 LocalFileEntity.self, LocalAudioFeaturesEntity.self, CuePointEntity.self,
            configurations: .init(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    /// Builds a CollectionItemEntity + cached ReleaseDetailEntity pair, mirroring what a
    /// real Discogs sync leaves behind before synthesis runs.
    private static func makeRelease(
        context: ModelContext, releaseId: Int = 100, releaseArtists: [String],
        tracklist: [Track], mbid: String? = nil
    ) throws -> CollectionItemEntity {
        let entity = CollectionItemEntity(instanceId: releaseId, releaseId: releaseId, folderId: 0, rating: 0, dateAdded: "2024-01-01")
        entity.mbid = mbid
        let basic = BasicInformationEntity(title: "Test Release", year: 2020, coverImage: "", thumb: "", genres: [], styles: [])
        basic.artists = releaseArtists.enumerated().map { ArtistCreditEntity(artistId: $0.offset, name: $0.element) }
        entity.basicInformation = basic
        context.insert(entity)

        let detail = ReleaseDetail(
            id: releaseId, title: "Test Release", year: 2020, country: nil, released: nil, barcode: nil,
            artists: releaseArtists.enumerated().map { ArtistCredit(id: $0.offset, name: $0.element) },
            labels: nil, formats: nil, genres: nil, styles: nil, tracklist: tracklist,
            extraartists: nil, identifiers: nil, notes: nil, masterId: nil, masterUrl: nil,
            dataQuality: nil, images: nil
        )
        let detailEntity = ReleaseDetailEntity(releaseId: releaseId, jsonData: try JSONEncoder().encode(detail))
        context.insert(detailEntity)

        return entity
    }

    // MARK: - A2: duration parsing

    @Test func durationParsesMinutesSeconds() {
        #expect(Track(position: "1", title: "t", duration: "4:32", artists: nil).durationMs == 272_000)
    }

    @Test func durationParsesHoursMinutesSeconds() {
        #expect(Track(position: "1", title: "t", duration: "1:04:32", artists: nil).durationMs == 3_872_000)
    }

    @Test func durationEmptyStringIsNil() {
        #expect(Track(position: "1", title: "t", duration: "", artists: nil).durationMs == nil)
    }

    @Test func durationJunkIsNil() {
        #expect(Track(position: "1", title: "t", duration: "not a duration", artists: nil).durationMs == nil)
        #expect(Track(position: "1", title: "t", duration: "4:xx", artists: nil).durationMs == nil)
    }

    // MARK: - A3: artist credit

    @Test func compilationUsesPerTrackArtist() throws {
        let context = try Self.makeContext()
        let tracklist = [Track(position: "1", title: "Song A", duration: "3:00",
                                artists: [ArtistCredit(id: 1, name: "Artist A")])]
        let entity = try Self.makeRelease(context: context, releaseArtists: ["Various"], tracklist: tracklist)

        let coordinator = RecordingsScanCoordinator(context: context)
        #expect(coordinator.synthesizeTracksForOrphanRelease(entity) == 1)
        #expect(entity.tracks.first?.artistCredit == "Artist A")
    }

    @Test func normalReleaseFallsBackToReleaseArtist() throws {
        let context = try Self.makeContext()
        let tracklist = [Track(position: "1", title: "Song A", duration: "3:00", artists: nil)]
        let entity = try Self.makeRelease(context: context, releaseArtists: ["Real Artist"], tracklist: tracklist)

        let coordinator = RecordingsScanCoordinator(context: context)
        #expect(coordinator.synthesizeTracksForOrphanRelease(entity) == 1)
        #expect(entity.tracks.first?.artistCredit == "Real Artist")
    }

    @Test func compilationTrackMissingPerTrackArtistFallsBackToReleaseArtist() throws {
        let context = try Self.makeContext()
        let tracklist = [Track(position: "1", title: "Song A", duration: "3:00", artists: nil)]
        let entity = try Self.makeRelease(context: context, releaseArtists: ["Various"], tracklist: tracklist)

        let coordinator = RecordingsScanCoordinator(context: context)
        #expect(coordinator.synthesizeTracksForOrphanRelease(entity) == 1)
        #expect(entity.tracks.first?.artistCredit == "Various")
    }

    // MARK: - A4: heading rows

    @Test func headingRowsAreSkipped() throws {
        let context = try Self.makeContext()
        let tracklist = [
            Track(position: "", title: "Side A", duration: "", artists: nil),
            Track(position: "1", title: "Song A", duration: "3:00", artists: nil)
        ]
        let entity = try Self.makeRelease(context: context, releaseArtists: ["Artist"], tracklist: tracklist)

        let coordinator = RecordingsScanCoordinator(context: context)
        #expect(coordinator.synthesizeTracksForOrphanRelease(entity) == 1)
        #expect(entity.tracks.count == 1)
        #expect(entity.tracks.first?.title == "Song A")
    }

    // MARK: - A1/A5: idempotency & the hard constraint

    @Test func runningTwiceCreatesNothingSecondTime() throws {
        let context = try Self.makeContext()
        let tracklist = [Track(position: "1", title: "Song A", duration: "3:00", artists: nil)]
        let entity = try Self.makeRelease(context: context, releaseArtists: ["Artist"], tracklist: tracklist)

        let coordinator = RecordingsScanCoordinator(context: context)
        #expect(coordinator.synthesizeTracksForOrphanRelease(entity) == 1)
        #expect(coordinator.synthesizeTracksForOrphanRelease(entity) == 0)
        #expect(entity.tracks.count == 1)
    }

    @Test func releaseWithExistingMusicBrainzTracksIsUntouched() throws {
        let context = try Self.makeContext()
        let tracklist = [Track(position: "1", title: "Song A", duration: "3:00", artists: nil)]
        let entity = try Self.makeRelease(context: context, releaseArtists: ["Artist"],
                                           tracklist: tracklist, mbid: "mb-release-id")
        // Simulate a real MusicBrainz-fetched track already present — this is what every
        // one of the 187 confident file matches is keyed on.
        let existing = TrackEntity(trackMBID: "mb-track-1", recordingMBID: "mb-recording-1",
                                    position: "1", title: "Real MB Title", durationMs: 200_000,
                                    artistCredit: "Real MB Artist")
        existing.collectionItem = entity
        context.insert(existing)

        let coordinator = RecordingsScanCoordinator(context: context)
        #expect(coordinator.synthesizeTracksForOrphanRelease(entity) == 0)
        #expect(entity.tracks.count == 1)
        #expect(entity.tracks.first?.trackMBID == "mb-track-1")
        #expect(entity.tracks.first?.title == "Real MB Title")
    }

    // MARK: - Recordings fetch enriches, never replaces

    private static func rec(_ trackMBID: String, _ position: String, recording: String = "rec",
                            ms: Int? = 180_000, artist: String = "MB Artist") -> RecordingMBIDMatch {
        RecordingMBIDMatch(trackMBID: trackMBID, recordingMBID: recording, position: position,
                           title: "MB Title", durationMs: ms, artistCredit: artist)
    }

    private static func discogsTrack(_ position: String, in entity: CollectionItemEntity, context: ModelContext,
                                     ms: Int? = 200_000, artist: String = "Discogs Artist") -> TrackEntity {
        let t = TrackEntity(trackMBID: "discogs:100:\(position)", recordingMBID: "", position: position,
                            title: "Discogs Title", durationMs: ms, artistCredit: artist)
        t.collectionItem = entity
        context.insert(t)
        return t
    }

    @Test func linkedAnalyzedDiscogsTrackKeepsLinkAndFeatures() throws {
        let context = try Self.makeContext()
        let entity = try Self.makeRelease(context: context, releaseArtists: ["Artist"], tracklist: [], mbid: "mb")
        let track = Self.discogsTrack("A1", in: entity, context: context)
        let file = LocalFileEntity(filePath: "/m/A1.flac", fileName: "A1.flac", format: "flac", fileSizeBytes: nil)
        file.bpm = 124; file.camelot = "8A"
        file.track = track
        context.insert(file)
        track.fileMatchState = "confident"
        track.primaryLocalFilePath = "/m/A1.flac"
        track.candidateFilePaths = ["/m/A1.flac"]
        let features = LocalAudioFeaturesEntity()
        features.bpm = 124; features.camelot = "8A"
        context.insert(features)
        track.localAudioFeatures = features
        try context.save()

        RecordingsScanCoordinator(context: context).mergeRecordings([Self.rec("mb-a1", "a 1", recording: "rec-a1")], into: entity)
        try context.save()

        #expect(entity.tracks.count == 1)
        let t = try #require(entity.tracks.first)
        #expect(t.trackMBID == "discogs:100:A1")          // identity untouched
        #expect(t.recordingMBID == "rec-a1")              // empty field filled
        #expect(t.fileMatchState == "confident")
        #expect(t.primaryLocalFilePath == "/m/A1.flac")
        #expect(t.candidateFilePaths == ["/m/A1.flac"])
        #expect(t.localFiles.map(\.filePath) == ["/m/A1.flac"])
        #expect(t.effectiveBpm == 124)
        #expect(t.effectiveCamelot == "8A")
    }

    @Test func emptyDurationIsFilled() throws {
        let context = try Self.makeContext()
        let entity = try Self.makeRelease(context: context, releaseArtists: ["Artist"], tracklist: [], mbid: "mb")
        let track = Self.discogsTrack("1", in: entity, context: context, ms: nil)
        RecordingsScanCoordinator(context: context).mergeRecordings([Self.rec("mb-1", "1", ms: 181_000)], into: entity)
        #expect(track.durationMs == 181_000)
    }

    @Test func nonEmptyArtistCreditIsNotOverwritten() throws {
        let context = try Self.makeContext()
        let entity = try Self.makeRelease(context: context, releaseArtists: ["Artist"], tracklist: [], mbid: "mb")
        let track = Self.discogsTrack("1", in: entity, context: context, ms: 200_000, artist: "Discogs Artist")
        RecordingsScanCoordinator(context: context).mergeRecordings([Self.rec("mb-1", "1", ms: 999_000)], into: entity)
        #expect(track.artistCredit == "Discogs Artist")
        #expect(track.durationMs == 200_000)              // non-empty duration kept too
        #expect(track.title == "Discogs Title")
    }

    @Test func musicBrainzOnlyPositionIsAdded() throws {
        let context = try Self.makeContext()
        let entity = try Self.makeRelease(context: context, releaseArtists: ["Artist"], tracklist: [], mbid: "mb")
        _ = Self.discogsTrack("1", in: entity, context: context)
        RecordingsScanCoordinator(context: context).mergeRecordings(
            [Self.rec("mb-1", "1"), Self.rec("mb-2", "2", recording: "rec-2")], into: entity)
        try context.save()
        #expect(entity.tracks.count == 2)
        let added = try #require(entity.tracks.first { $0.position == "2" })
        #expect(added.trackMBID == "mb-2")
        #expect(added.recordingMBID == "rec-2")
    }

    @Test func localOnlyPositionSurvives() throws {
        let context = try Self.makeContext()
        let entity = try Self.makeRelease(context: context, releaseArtists: ["Artist"], tracklist: [], mbid: "mb")
        _ = Self.discogsTrack("A1", in: entity, context: context)
        let bonus = Self.discogsTrack("B3", in: entity, context: context)
        bonus.fileMatchState = "confident"
        bonus.primaryLocalFilePath = "/m/B3.flac"
        try context.save()
        RecordingsScanCoordinator(context: context).mergeRecordings([Self.rec("mb-a1", "A1")], into: entity)
        try context.save()
        #expect(entity.tracks.count == 2)
        let kept = try #require(entity.tracks.first { $0.position == "B3" })
        #expect(kept.recordingMBID == "")
        #expect(kept.primaryLocalFilePath == "/m/B3.flac")
    }

    @Test func refetchPairsByTrackMBIDAndInsertsNothing() throws {
        // Multi-disc MB release fetched before: positions repeat ("1", "1"), so pairing must use
        // trackMBID first or the second disc would be inserted as a duplicate.
        let context = try Self.makeContext()
        let entity = try Self.makeRelease(context: context, releaseArtists: ["Artist"], tracklist: [], mbid: "mb")
        for id in ["mb-d1t1", "mb-d2t1"] {
            let t = TrackEntity(trackMBID: id, recordingMBID: "", position: "1", title: id, durationMs: nil, artistCredit: "")
            t.collectionItem = entity
            context.insert(t)
        }
        RecordingsScanCoordinator(context: context).mergeRecordings(
            [Self.rec("mb-d1t1", "1", recording: "r1"), Self.rec("mb-d2t1", "1", recording: "r2")], into: entity)
        try context.save()
        #expect(entity.tracks.count == 2)
        #expect(Dictionary(uniqueKeysWithValues: entity.tracks.map { ($0.trackMBID, $0.recordingMBID) })
                == ["mb-d1t1": "r1", "mb-d2t1": "r2"])
    }
}
