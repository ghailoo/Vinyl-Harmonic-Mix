//
//  StoreMigrationTests.swift
//  VinylHarmonicMixTests
//
//  The one-time copy of the store out of the old sandbox container. Uses real SQLite files
//  in a temp folder — never the user's library.
//

import Testing
import SwiftData
import Foundation
@testable import VinylHarmonicMix

@MainActor
struct StoreMigrationTests {

    private let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("StoreMigrationTests-\(UUID().uuidString)")
    private var newURL: URL { root.appendingPathComponent("new/default.store") }
    private var oldURL: URL { root.appendingPathComponent("old/default.store") }

    /// Writes `releases` rows to a store at `url`, released before returning so the files are idle.
    private func seed(_ url: URL, releases: Int) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let container = try ModelContainer(for: VinylHarmonicMixApp.schema, configurations: ModelConfiguration(url: url))
        let ctx = ModelContext(container)
        for i in 0..<releases {
            ctx.insert(CollectionItemEntity(instanceId: i, releaseId: i, folderId: 0, rating: 0, dateAdded: "2024-01-01"))
        }
        try ctx.save()
    }

    private func open() throws -> Int {
        let container = try VinylHarmonicMixApp.openStore(schema: VinylHarmonicMixApp.schema, at: newURL, legacyURL: oldURL)
        return try ModelContext(container).fetchCount(FetchDescriptor<CollectionItemEntity>())
    }

    @Test func copiesLegacyStoreAndLeavesOriginal() throws {
        try seed(oldURL, releases: 3)
        #expect(try open() == 3)
        #expect(FileManager.default.fileExists(atPath: oldURL.path))
        #expect(!FileManager.default.fileExists(atPath: newURL.path + ".migrating"))
    }

    @Test func existingNewStoreWinsOverLegacy() throws {
        try seed(oldURL, releases: 3)
        try seed(newURL, releases: 5)
        #expect(try open() == 5)
    }

    @Test func noStoresAnywhereStartsFresh() throws {
        #expect(try open() == 0)
    }

    @Test func unreadableLegacyStoreFailsWithoutCreatingEmptyStore() throws {
        try seed(oldURL, releases: 3)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: oldURL.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: oldURL.path) }

        #expect(throws: VinylHarmonicMixApp.StoreError.self) { try open() }
        #expect(!FileManager.default.fileExists(atPath: newURL.path))
        #expect(FileManager.default.fileExists(atPath: oldURL.path))
    }
}
