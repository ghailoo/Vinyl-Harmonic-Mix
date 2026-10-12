//
//  PythonChoiceTests.swift
//  VinylHarmonicMixTests
//
//  Which interpreter runs Essentia: one that already has it, else a Homebrew Python
//  Essentia ships wheels for — never an install into Apple's /usr/bin/python3.
//

import Testing
@testable import VinylHarmonicMix

struct PythonChoiceTests {
    typealias P = LocalAnalysisCoordinator.PythonChoice
    let brew315 = P(path: "/opt/homebrew/bin/python3", minor: 15, hasEssentia: false)
    let brew312 = P(path: "/opt/homebrew/bin/python3.12", minor: 12, hasEssentia: false)
    let system  = P(path: "/usr/bin/python3", minor: 9, hasEssentia: false)

    @Test func prefersHomebrewWithWheelOverSystemAndUnsupported() {
        #expect(LocalAnalysisCoordinator.choosePython([brew315, brew312, system]).path == brew312.path)
    }

    @Test func keepsAnExistingEssentiaInstallEvenInSystemPython() {
        let systemWithEssentia = P(path: system.path, minor: 9, hasEssentia: true)
        #expect(LocalAnalysisCoordinator.choosePython([brew312, systemWithEssentia]).path == system.path)
    }

    @Test func neverOffersToInstallIntoSystemPython() {
        let choice = LocalAnalysisCoordinator.choosePython([system])
        #expect(choice.path == system.path)
        #expect(!choice.canInstallEssentia)
        #expect(!brew315.canInstallEssentia)
    }

    @Test func candidatesEndWithSystemPython() {
        #expect(LocalAnalysisCoordinator.python3Candidates().last == "/usr/bin/python3")
    }
}
