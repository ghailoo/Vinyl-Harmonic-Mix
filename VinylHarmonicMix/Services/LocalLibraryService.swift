import Foundation

/// One library root the user picked. `id` is stamped onto every LocalFileEntity indexed
/// from it (`libraryFolderID`) so per-folder operations (orphan sweep) can be scoped.
nonisolated struct LibraryFolder: Codable, Identifiable, Equatable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable {
        case albums, compilations, singles, other
        var label: String { rawValue.capitalized }
    }

    var id: UUID
    var bookmark: Data
    var displayPath: String
    var kind: Kind

    /// True when `path` is this folder's root or anything beneath it.
    func contains(path: String) -> Bool {
        LocalLibraryService.isPath(path, within: displayPath)
    }
}

enum LocalLibraryService {

    // Legacy single-folder keys (pre-v2.1). Still read for migration and left in place,
    // so rolling back to the v2.1-pre-multifolder tag keeps working.
    static let bookmarkKey    = "localLibraryBookmark"
    static let displayPathKey = "localLibraryDisplayPath"
    static let foldersKey     = "localLibraryFolders"

    nonisolated private static let audioExtensions: Set<String> = [
        "flac", "mp3", "aiff", "aif", "wav", "m4a", "mp4", "ogg", "opus"
    ]
    nonisolated private static let junkFolderNames: Set<String> = ["#recycle", "@eaDir"]

    // MARK: - Library folders

    enum FolderError: LocalizedError {
        case overlaps(existing: String)
        var errorDescription: String? {
            switch self {
            case .overlaps(let existing):
                return "This folder is the same as, inside, or contains \(existing). Indexing it twice would duplicate files."
            }
        }
    }

    /// Ordered folder list. First call after upgrading migrates the legacy single bookmark
    /// into entry #1 (kind = other) — same bookmark bytes, so access carries over untouched.
    static func folders(defaults: UserDefaults = .standard) -> [LibraryFolder] {
        if let data = defaults.data(forKey: foldersKey) {
            // Undecodable list → no folders (nothing gets swept), never a re-migration over it.
            return (try? JSONDecoder().decode([LibraryFolder].self, from: data)) ?? []
        }
        guard let legacy = defaults.data(forKey: bookmarkKey) else { return [] }
        let migrated = [LibraryFolder(id: UUID(), bookmark: legacy,
                                      displayPath: defaults.string(forKey: displayPathKey) ?? "",
                                      kind: .other)]
        saveFolders(migrated, defaults: defaults)
        print("[LIBRARY] Migrated legacy bookmark → folder list (\(migrated[0].displayPath))")
        return migrated
    }

    static func saveFolders(_ folders: [LibraryFolder], defaults: UserDefaults = .standard) {
        defaults.set(try? JSONEncoder().encode(folders), forKey: foldersKey)
    }

    @discardableResult
    static func addFolder(_ url: URL, kind: LibraryFolder.Kind, defaults: UserDefaults = .standard) throws -> LibraryFolder {
        var list = folders(defaults: defaults)
        let path = url.standardizedFileURL.path
        if let clash = list.first(where: { isPath(path, within: $0.displayPath) || isPath($0.displayPath, within: path) }) {
            throw FolderError.overlaps(existing: clash.displayPath)
        }
        let data = try url.bookmarkData(options: [.withSecurityScope],
                                        includingResourceValuesForKeys: nil, relativeTo: nil)
        let folder = LibraryFolder(id: UUID(), bookmark: data, displayPath: path, kind: kind)
        list.append(folder)
        saveFolders(list, defaults: defaults)
        return folder
    }

    /// Drops the entry only. Index rows and matches are left alone — rows keep their
    /// now-dangling libraryFolderID, which the orphan sweep never matches, so they're never swept.
    static func removeFolder(id: UUID, defaults: UserDefaults = .standard) {
        saveFolders(folders(defaults: defaults).filter { $0.id != id }, defaults: defaults)
    }

    static func setKind(_ kind: LibraryFolder.Kind, for id: UUID, defaults: UserDefaults = .standard) {
        var list = folders(defaults: defaults)
        guard let i = list.firstIndex(where: { $0.id == id }) else { return }
        list[i].kind = kind
        saveFolders(list, defaults: defaults)
    }

    /// Resolves a folder's bookmark. Caller must balance with stopAccessingSecurityScopedResource().
    static func resolve(_ folder: LibraryFolder, defaults: UserDefaults = .standard) -> URL? {
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: folder.bookmark,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else { return nil }
        if isStale, let fresh = try? url.bookmarkData(options: [.withSecurityScope],
                                                       includingResourceValuesForKeys: nil, relativeTo: nil) {
            var list = folders(defaults: defaults)
            if let i = list.firstIndex(where: { $0.id == folder.id }) {
                list[i].bookmark = fresh   // displayPath deliberately NOT rewritten — see DriveMonitor
                saveFolders(list, defaults: defaults)
            }
        }
        return url
    }

    /// Case-insensitive (APFS/SMB default) so "/Volumes/Music" and "/volumes/music/x" overlap.
    nonisolated static func isPath(_ path: String, within root: String) -> Bool {
        let p = path.lowercased(), r = root.lowercased()
        guard !r.isEmpty else { return false }
        let rootSlash = r.hasSuffix("/") ? r : r + "/"
        return p == r || p.hasPrefix(rootSlash)
    }

    // MARK: - Per-release linked folders ("Link folder…")

    static let linkedFoldersKey = "linkedReleaseFolders"   // [displayPath: security-scoped bookmark]

    /// True when `path` sits under one of the configured library folders (covered by future scans).
    static func isInLibrary(_ path: String, defaults: UserDefaults = .standard) -> Bool {
        folders(defaults: defaults).contains { $0.contains(path: path) }
    }

    /// Bookmarks a folder picked from a release sheet. Not a library folder — never scanned or swept.
    static func recordLinkedFolder(_ url: URL, defaults: UserDefaults = .standard) {
        var map = defaults.dictionary(forKey: linkedFoldersKey) as? [String: Data] ?? [:]
        map[url.standardizedFileURL.path] = try? url.bookmarkData(options: [.withSecurityScope],
                                                                   includingResourceValuesForKeys: nil, relativeTo: nil)
        defaults.set(map, forKey: linkedFoldersKey)
    }

    /// Launch: reopen every linked folder for the session (released at process exit), refreshing stale bookmarks.
    static func startAccessingLinkedFolders(defaults: UserDefaults = .standard) {
        let map = defaults.dictionary(forKey: linkedFoldersKey) as? [String: Data] ?? [:]
        for data in map.values {
            var isStale = false
            guard let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope],
                                     relativeTo: nil, bookmarkDataIsStale: &isStale) else { continue }
            _ = url.startAccessingSecurityScopedResource()
            if isStale { recordLinkedFolder(url, defaults: defaults) }
        }
    }

    /// Audio files directly in `url` (or anywhere beneath it when `recursive`), sorted by name.
    nonisolated static func audioFiles(in url: URL, recursive: Bool) -> [URL] {
        var options: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles, .skipsPackageDescendants]
        if !recursive { options.insert(.skipsSubdirectoryDescendants) }
        guard let enumerator = FileManager().enumerator(at: url, includingPropertiesForKeys: nil,
                                                        options: options) else { return [] }
        var out: [URL] = []
        while let fileURL = enumerator.nextObject() as? URL {
            if junkFolderNames.contains(fileURL.lastPathComponent) { enumerator.skipDescendants(); continue }
            if audioExtensions.contains(fileURL.pathExtension.lowercased()) { out.append(fileURL) }
        }
        return out.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// True when any subfolder of `url` holds audio. Stops at the first hit.
    nonisolated static func hasNestedAudio(in url: URL) -> Bool {
        guard let enumerator = FileManager().enumerator(at: url, includingPropertiesForKeys: nil,
                                                        options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return false }
        while let fileURL = enumerator.nextObject() as? URL {
            if junkFolderNames.contains(fileURL.lastPathComponent) { enumerator.skipDescendants(); continue }
            if enumerator.level > 1, audioExtensions.contains(fileURL.pathExtension.lowercased()) { return true }
        }
        return false
    }

    // MARK: - Audio file count

    static func countAudioFiles(in url: URL) async throws -> Int {
        try await Task.detached(priority: .utility) {
            guard url.startAccessingSecurityScopedResource() else {
                throw LibraryError.accessDenied
            }
            defer { url.stopAccessingSecurityScopedResource() }
            return try countRecursive(in: url)
        }.value
    }

    // nonisolated: only touches FileManager, no actor state.
    nonisolated private static func countRecursive(in url: URL) throws -> Int {
        let fm = FileManager()
        var count = 0
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return 0 }

        // Use nextObject() — for-in over NSDirectoryEnumerator is unavailable in async contexts.
        while let obj = enumerator.nextObject() {
            guard let fileURL = obj as? URL else { continue }
            let name = fileURL.lastPathComponent
            if junkFolderNames.contains(name) {
                enumerator.skipDescendants()
                continue
            }
            if audioExtensions.contains(fileURL.pathExtension.lowercased()) {
                count += 1
            }
        }
        return count
    }

    // MARK: - fpcalc detection + execution test

    /// A GUI app doesn't inherit the shell PATH, so look in Homebrew's dirs explicitly
    /// (Apple silicon, Intel), then /usr/bin.
    static let fpcalcSearchPaths = ["/opt/homebrew/bin/fpcalc", "/usr/local/bin/fpcalc", "/usr/bin/fpcalc"]

    static var fpcalcNotFoundMessage: String {
        "fpcalc not found (looked in \(fpcalcSearchPaths.joined(separator: ", "))). Install with: brew install chromaprint"
    }

    static func fpcalcPath() -> String? {
        // isExecutableFile returns false inside the sandbox for binaries outside the container.
        // fileExists works because existence checks are not permission-gated the same way.
        fpcalcSearchPaths.first { FileManager.default.fileExists(atPath: $0) }
    }

    enum FpcalcExecutionResult {
        case success(String)
        case notFound
        case executionFailed(String)
    }

    static func testFpcalcExecution() async -> FpcalcExecutionResult {
        guard let path = fpcalcPath() else { return .notFound }
        return await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = ["-version"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            do {
                try process.run()
                process.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if process.terminationStatus == 0 {
                    return .success(output)
                } else {
                    return .executionFailed(output.isEmpty ? "exit \(process.terminationStatus)" : output)
                }
            } catch {
                return .executionFailed(error.localizedDescription)
            }
        }.value
    }

    // MARK: - AcoustID key validation

    enum AcoustIDTestResult {
        case valid
        case invalidKey
        case networkError(String)
    }

    static func testAcoustIDKey(_ key: String) async -> AcoustIDTestResult {
        guard !key.trimmingCharacters(in: .whitespaces).isEmpty else { return .invalidKey }
        let urlString = "https://api.acoustid.org/v2/lookup?client=\(key)&meta=recordings&trackid=0c62ff88-f13f-42e8-a88d-d0332a8c3e03"
        guard let url = URL(string: urlString) else { return .networkError("Bad URL") }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            struct Payload: Decodable {
                struct AcoustIDError: Decodable { let code: Int }
                let error: AcoustIDError?
            }
            let payload = try JSONDecoder().decode(Payload.self, from: data)
            return payload.error?.code == 4 ? .invalidKey : .valid
        } catch {
            return .networkError(error.localizedDescription)
        }
    }

    // MARK: - Errors

    enum LibraryError: LocalizedError {
        case accessDenied
        var errorDescription: String? {
            "Cannot start security-scoped access — bookmark may be stale."
        }
    }
}
