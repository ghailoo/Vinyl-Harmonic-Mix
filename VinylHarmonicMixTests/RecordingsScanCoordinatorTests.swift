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
}
