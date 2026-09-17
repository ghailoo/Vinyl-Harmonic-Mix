//
//  MBMatchVerifierTests.swift
//  VinylHarmonicMixTests
//
//  Pure-function tests for Part B1 normalization and B2 scoring — no network.
//

import Testing
@testable import VinylHarmonicMix

struct MBMatchVerifierTests {

    @Test func stripsDiscogsDisambiguationSuffix() {
        #expect(MBMatchVerifier.stripDiscogsArtistSuffix("Madonna (2)") == "Madonna")
        #expect(MBMatchVerifier.stripDiscogsArtistSuffix("Blur") == "Blur")
    }

    @Test func multiArtistCreditTakesBestMatch() {
        let candidate = MBCandidate(
            mbid: "1", title: "Homework", artist: "Daft Punk", date: nil, country: nil,
            barcode: nil, catalogNumbers: [], labels: [], formats: [], trackCount: nil, mbScore: nil
        )
        let wrongOnly = MBMatchVerifier.DiscogsSide(
            artists: ["Some Other Artist"], title: "Homework", formats: [],
            catalogNumber: nil, country: nil, year: nil, trackCount: nil
        )
        let withCorrectCredit = MBMatchVerifier.DiscogsSide(
            artists: ["Some Other Artist", "Daft Punk"], title: "Homework", formats: [],
            catalogNumber: nil, country: nil, year: nil, trackCount: nil
        )
        let wrongScore = MBMatchVerifier.score(candidate: candidate, discogs: wrongOnly) ?? 0
        let correctScore = MBMatchVerifier.score(candidate: candidate, discogs: withCorrectCredit)
        #expect(correctScore != nil)
        #expect(correctScore! >= MBMatchThresholds.reviewMinimum)
        #expect(correctScore! > wrongScore)
    }

    @Test func remixParentheticalTitleStillMatches() {
        let discogs = MBMatchVerifier.DiscogsSide(
            artists: ["Artist"], title: "Track Name (Extended Mix)",
            formats: [], catalogNumber: nil, country: nil, year: nil, trackCount: nil
        )
        let candidate = MBCandidate(
            mbid: "1", title: "Track Name (Radio Edit)", artist: "Artist", date: nil, country: nil,
            barcode: nil, catalogNumbers: [], labels: [], formats: [], trackCount: nil, mbScore: nil
        )
        let score = MBMatchVerifier.score(candidate: candidate, discogs: discogs)
        #expect(score != nil)
        #expect(score! >= MBMatchThresholds.reviewMinimum)
    }

    @Test func cdCandidateRejectedForVinylRelease() {
        let discogs = MBMatchVerifier.DiscogsSide(
            artists: ["Artist"], title: "Album", formats: ["Vinyl", "12\""],
            catalogNumber: nil, country: nil, year: nil, trackCount: nil
        )
        let candidate = MBCandidate(
            mbid: "1", title: "Album", artist: "Artist", date: nil, country: nil,
            barcode: nil, catalogNumbers: [], labels: [], formats: ["CD"], trackCount: nil, mbScore: nil
        )
        #expect(MBMatchVerifier.score(candidate: candidate, discogs: discogs) == nil)
    }

    @Test func yearOffByOneStillAccepted() {
        let discogs = MBMatchVerifier.DiscogsSide(
            artists: ["Artist"], title: "Album", formats: [],
            catalogNumber: nil, country: nil, year: 1999, trackCount: nil
        )
        let candidate = MBCandidate(
            mbid: "1", title: "Album", artist: "Artist", date: "2000-01-01", country: nil,
            barcode: nil, catalogNumbers: [], labels: [], formats: [], trackCount: nil, mbScore: nil
        )
        let score = MBMatchVerifier.score(candidate: candidate, discogs: discogs)
        #expect(score != nil)
        #expect(score! >= MBMatchThresholds.reviewMinimum)
    }
}
