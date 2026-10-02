//
//  ReleaseFolderMatcherTests.swift
//  VinylHarmonicMixTests
//
//  Pure-function tests for "Link folder…" pairing: number → title → duration trust order.
//

import Testing
@testable import VinylHarmonicMix

struct ReleaseFolderMatcherTests {

    private typealias T = ReleaseFolderMatcher.TrackInfo
    private typealias F = ReleaseFolderMatcher.FileInfo

    private static func file(_ name: String, ms: Int = 0) -> F {
        F(path: "/x/\(name)", fileName: name, durationMs: ms)
    }

    private static func pairs(_ p: [ReleaseFolderMatcher.Proposal]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: p.map { ($0.trackMBID, $0.filePath) })
    }

    @Test func leadingTokens() {
        #expect(ReleaseFolderMatcher.leadingToken("03 - Title.flac") == "3")
        #expect(ReleaseFolderMatcher.leadingToken("a2. Title.mp3") == "A2")
        #expect(ReleaseFolderMatcher.leadingToken("10cc - Title.mp3") == nil)
        #expect(ReleaseFolderMatcher.leadingToken("Title.flac") == nil)
    }

    @Test func numberedFolderGetsStraightOrder() {
        // Discogs vinyl positions, files numbered by running order, listed out of order.
        let tracks = [T(trackMBID: "discogs:1:A1", position: "A1", title: "Alpha", durationMs: 0),
                      T(trackMBID: "discogs:1:A2", position: "A2", title: "Beta", durationMs: 0),
                      T(trackMBID: "discogs:1:B1", position: "B1", title: "Gamma", durationMs: 0)]
        let files = [Self.file("02 Something.flac"), Self.file("03 Else.flac"), Self.file("01 Whatever.flac")]
        let p = ReleaseFolderMatcher.propose(tracks: tracks, files: files)
        #expect(p.allSatisfy { $0.reason == .order })
        #expect(Self.pairs(p) == ["discogs:1:A1": "/x/01 Whatever.flac",
                                  "discogs:1:A2": "/x/02 Something.flac",
                                  "discogs:1:B1": "/x/03 Else.flac"])
    }

    @Test func numberBeatsMisleadingTitle() {
        // File 1 is titled like track 2 — the number still wins; extra file is left over.
        let tracks = [T(trackMBID: "a", position: "1", title: "Night Drive", durationMs: 0),
                      T(trackMBID: "b", position: "2", title: "Day Off", durationMs: 0)]
        let files = [Self.file("01 Day Off (Intro).flac"), Self.file("02 Day Off.flac"), Self.file("cover.wav")]
        let p = ReleaseFolderMatcher.propose(tracks: tracks, files: files)
        #expect(Self.pairs(p) == ["a": "/x/01 Day Off (Intro).flac", "b": "/x/02 Day Off.flac"])
        #expect(p.allSatisfy { $0.reason == .number })
    }

    @Test func unnumberedFallsBackToTitleThenDuration() {
        let tracks = [T(trackMBID: "a", position: "1", title: "Blue Monday", durationMs: 450_000),
                      T(trackMBID: "b", position: "2", title: "Blue Monday", durationMs: 220_000)]
        let files = [Self.file("New Order - Blue Monday.flac", ms: 221_000),
                     Self.file("Blue Monday.mp3", ms: 449_000),
                     Self.file("Unrelated Song.mp3")]
        let p = ReleaseFolderMatcher.propose(tracks: tracks, files: files)
        #expect(Self.pairs(p) == ["a": "/x/Blue Monday.mp3", "b": "/x/New Order - Blue Monday.flac"])
        #expect(p.allSatisfy { $0.reason == .title })
    }

    @Test func multiDiscRepeatsAreNotStraightOrdered() {
        // MusicBrainz 2-disc: positions repeat, filenames "1-01"/"2-01" collide on the number.
        let tracks = [T(trackMBID: "a", position: "1", title: "First", durationMs: 0),
                      T(trackMBID: "b", position: "1", title: "Second", durationMs: 0)]
        let files = [Self.file("1-01 Second.flac"), Self.file("2-01 First.flac")]
        let p = ReleaseFolderMatcher.propose(tracks: tracks, files: files)
        #expect(Self.pairs(p) == ["a": "/x/2-01 First.flac", "b": "/x/1-01 Second.flac"])
    }
}
