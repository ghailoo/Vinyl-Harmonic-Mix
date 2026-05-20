import Foundation

enum LocalLibraryService {

    static let bookmarkKey    = "localLibraryBookmark"
    static let displayPathKey = "localLibraryDisplayPath"

    private static let audioExtensions: Set<String> = [
        "flac", "mp3", "aiff", "aif", "wav", "m4a", "mp4", "ogg", "opus"
    ]
    private static let junkFolderNames: Set<String> = ["#recycle", "@eaDir"]

    // MARK: - Bookmark management

    static func saveBookmark(for url: URL) throws {
        let data = try url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        UserDefaults.standard.set(data, forKey: bookmarkKey)
        UserDefaults.standard.set(url.path, forKey: displayPathKey)
    }

    /// Resolves the stored bookmark. Caller must balance with stopAccessingSecurityScopedResource().
    static func resolveLibraryBookmark() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else { return nil }
        if isStale { try? saveBookmark(for: url) }
        return url
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

    private static func countRecursive(in url: URL) throws -> Int {
        let fm = FileManager()
        var count = 0
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return 0 }

        for case let fileURL as URL in enumerator {
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

    static func fpcalcPath() -> String? {
        // isExecutableFile returns false inside the sandbox for binaries outside the container.
        // fileExists works because existence checks are not permission-gated the same way.
        ["/opt/homebrew/bin/fpcalc", "/usr/local/bin/fpcalc", "/usr/bin/fpcalc"]
            .first { FileManager.default.fileExists(atPath: $0) }
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
