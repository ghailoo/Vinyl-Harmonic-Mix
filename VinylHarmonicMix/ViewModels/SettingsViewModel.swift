import Foundation

@Observable
final class SettingsViewModel {
    // MARK: - Discogs
    var token: String = ""
    var username: String = ""
    var isValidating = false
    var isTokenValidated = false
    var errorMessage: String? = nil
    var successMessage: String? = nil

    // MARK: - MusicBrainz
    var mbContactEmail: String = ""
    var mbIsTesting = false
    var mbSuccessMessage: String? = nil
    var mbErrorMessage: String? = nil

    // MARK: - Local Audio Library
    var libraryFolderError: String? = nil
    var acoustIDKey: String = ""
    var libraryTestStatus: [UUID: LibraryTestStatus] = [:]   // per folder, D3
    var acoustIDTestStatus: AcoustIDTestStatus = .idle
    var isTestingLibrary = false
    var isTestingAcoustID = false
    private(set) var fpcalcStatus: FpcalcStatus = .notFound

    var scanProgress: LibraryScanProgress? = nil
    private var libraryScanTask: Task<Void, Never>? = nil

    struct LibraryScanProgress {
        var audioFilesFound: Int = 0
        var itemsExamined: Int = 0
        var currentFolder: String = ""
        var isComplete: Bool = false
        var finalCount: Int = 0
    }

    enum LibraryTestStatus: Equatable {
        case idle
        case accessible(count: Int)
        case unreachable
        case empty
    }

    enum AcoustIDTestStatus: Equatable {
        case idle, valid, invalid
        case networkError(String)
    }

    enum FpcalcStatus: Equatable {
        case found(path: String)
        case notFound
    }

    enum FpcalcExecutionStatus: Equatable {
        case idle
        case success(String)   // version string from fpcalc -version
        case blocked(String)   // process.run() threw — sandbox denial or similar
    }

    var fpcalcExecutionStatus: FpcalcExecutionStatus = .idle
    var isTestingFpcalc = false

    private let keychain = KeychainService.shared
    private let client = DiscogsClient()
    private let mbClient = MusicBrainzClient()

    init() {
        token = keychain.load(for: .token) ?? ""
        username = keychain.load(for: .username) ?? ""
        mbContactEmail = keychain.load(for: .musicbrainzContactEmail) ?? ""
        acoustIDKey = keychain.load(for: .acoustIDKey) ?? ""
        checkFpcalc()
    }

    func save() {
        errorMessage = nil
        do {
            try keychain.save(token, for: .token)
            try keychain.save(username, for: .username)
            try keychain.save(mbContactEmail, for: .musicbrainzContactEmail)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func testToken() async {
        isValidating = true
        errorMessage = nil
        successMessage = nil
        defer { isValidating = false }
        do {
            let identity = try await client.validateToken(token)
            isTokenValidated = true
            successMessage = "Connected as @\(identity.username)"
        } catch {
            isTokenValidated = false
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Local Audio Library actions

    func addLibraryFolder(_ url: URL, kind: LibraryFolder.Kind) {
        libraryFolderError = nil
        do {
            try LocalLibraryService.addFolder(url, kind: kind)
        } catch {
            libraryFolderError = error.localizedDescription
        }
    }

    /// Walks each folder in turn and records a result per folder, so one unreachable
    /// folder shows as such without hiding the others' results.
    func testLibraryAccess(folders: [LibraryFolder]) {
        libraryScanTask?.cancel()
        scanProgress = LibraryScanProgress()
        libraryTestStatus = [:]
        isTestingLibrary = true

        libraryScanTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let audioExtensions: Set<String> = ["flac","mp3","aiff","aif","wav","m4a","mp4","ogg","opus"]
            let skipDirs: Set<String> = ["#recycle","@eaDir",".Trashes",".Spotlight-V100"]
            var totalAudio = 0

            for folder in folders {
                guard let url = await MainActor.run(body: { LocalLibraryService.resolve(folder) }),
                      DriveMonitor.isDeepAccessible(url: url, expectedPath: folder.displayPath) else {
                    await MainActor.run { self.libraryTestStatus[folder.id] = .unreachable }
                    continue
                }

                let didAccess = url.startAccessingSecurityScopedResource()
                defer { if didAccess { url.stopAccessingSecurityScopedResource() } }

                guard let enumerator = FileManager().enumerator(
                    at: url,
                    includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
                    options: [.skipsHiddenFiles]
                ) else {
                    await MainActor.run { self.libraryTestStatus[folder.id] = .unreachable }
                    continue
                }

                var audioCount = 0
                var examined = 0

                // Use nextObject() — for-in over NSDirectoryEnumerator is unavailable in async contexts.
                while let obj = enumerator.nextObject() {
                    guard let fileURL = obj as? URL else { continue }

                    if Task.isCancelled {
                        await MainActor.run {
                            self.scanProgress = nil
                            self.isTestingLibrary = false
                        }
                        return
                    }

                    examined += 1

                    if skipDirs.contains(fileURL.lastPathComponent) {
                        enumerator.skipDescendants()
                        continue
                    }

                    if audioExtensions.contains(fileURL.pathExtension.lowercased()) {
                        audioCount += 1
                    }

                    if examined % 250 == 0 {
                        let snap = (audio: totalAudio + audioCount, examined: examined,
                                    folder: fileURL.deletingLastPathComponent().lastPathComponent)
                        await MainActor.run {
                            self.scanProgress?.audioFilesFound = snap.audio
                            self.scanProgress?.itemsExamined = snap.examined
                            self.scanProgress?.currentFolder = snap.folder
                        }
                    }
                }

                totalAudio += audioCount
                let count = audioCount
                await MainActor.run {
                    self.libraryTestStatus[folder.id] = count > 0 ? .accessible(count: count) : .empty
                }
            }

            let finalCount = totalAudio
            await MainActor.run {
                self.scanProgress?.audioFilesFound = finalCount
                self.scanProgress?.isComplete = true
                self.scanProgress?.finalCount = finalCount
                self.isTestingLibrary = false
            }

            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled {
                await MainActor.run { self.scanProgress = nil }
            }
        }
    }

    func cancelLibraryScan() {
        libraryScanTask?.cancel()
        libraryScanTask = nil
        scanProgress = nil
        isTestingLibrary = false
    }

    func saveAcoustIDKey() {
        try? keychain.save(acoustIDKey, for: .acoustIDKey)
    }

    func testAcoustIDKey() async {
        isTestingAcoustID = true
        acoustIDTestStatus = .idle
        defer { isTestingAcoustID = false }
        saveAcoustIDKey()
        let result = await LocalLibraryService.testAcoustIDKey(acoustIDKey)
        switch result {
        case .valid:                   acoustIDTestStatus = .valid
        case .invalidKey:              acoustIDTestStatus = .invalid
        case .networkError(let msg):   acoustIDTestStatus = .networkError(msg)
        }
    }

    func checkFpcalc() {
        if let path = LocalLibraryService.fpcalcPath() {
            fpcalcStatus = .found(path: path)
        } else {
            fpcalcStatus = .notFound
        }
    }

    func testFpcalcExecution() async {
        isTestingFpcalc = true
        fpcalcExecutionStatus = .idle
        defer { isTestingFpcalc = false }
        let result = await LocalLibraryService.testFpcalcExecution()
        switch result {
        case .success(let version):        fpcalcExecutionStatus = .success(version)
        case .notFound:                    fpcalcExecutionStatus = .blocked("fpcalc not found")
        case .executionFailed(let msg):    fpcalcExecutionStatus = .blocked(msg)
        }
    }

    func testMBConnection() async {
        mbIsTesting = true
        mbErrorMessage = nil
        mbSuccessMessage = nil
        defer { mbIsTesting = false }
        do {
            let latency = try await mbClient.testConnection(contactEmail: mbContactEmail)
            let ms = Int((latency * 1000).rounded())
            mbSuccessMessage = "Reachable · ~\(ms) ms"
        } catch {
            mbErrorMessage = "Unreachable: \(error.localizedDescription)"
        }
    }
}
