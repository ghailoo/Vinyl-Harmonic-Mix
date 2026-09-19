//
//  FuzzyMatchTests.swift
//  VinylHarmonicMixTests
//
//  Pure-function tests for version-match normalization and the shared threshold
//  (FileMatchCoordinator's confident/review tiering and FileMatchesView's mixCheck both
//  read FuzzyMatch.versionMatchThreshold, so a single test here covers both call sites).
//

import Testing
@testable import VinylHarmonicMix

struct FuzzyMatchTests {

    /// Runs each fragment through splitVersion (as real titles/filenames would) so the
    /// comparison matches what versionSimilarity actually sees in production.
    private static func versionScore(_ a: String, _ b: String) -> Double {
        let va = FuzzyMatch.splitVersion("Song (\(a))").version
        let vb = FuzzyMatch.splitVersion("Song (\(b))").version
        return FuzzyMatch.versionSimilarity(va, vb)
    }

    @Test func inchMarksAndSlashesReadAsSameMix() {
        #expect(Self.versionScore("7″ version", "7'' Version") >= FuzzyMatch.versionMatchThreshold)
        #expect(Self.versionScore("Radio Edit", "radio edit") >= FuzzyMatch.versionMatchThreshold)
        #expect(Self.versionScore("Club/Dub", "Club Dub") >= FuzzyMatch.versionMatchThreshold)
    }

    @Test func distinctMixesReadAsDifferent() {
        #expect(Self.versionScore("Techno mix", "Swe-Tech Mix") < FuzzyMatch.versionMatchThreshold)
        #expect(Self.versionScore("Gregorian dub", "Swe&me Mix") < FuzzyMatch.versionMatchThreshold)
        #expect(Self.versionScore("Red Zone mix", "The Re-modelled Remix") < FuzzyMatch.versionMatchThreshold)
    }
}
