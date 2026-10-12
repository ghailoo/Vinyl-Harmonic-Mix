import Foundation
import SwiftData

@MainActor
@Observable
final class LocalAnalysisCoordinator {

    // MARK: - Single source of truth: python3 path
    //
    // Both the analysis subprocess and the pip installer use this exact path.
    // A GUI app gets PATH=/usr/bin:/bin:…, so `which python3` only ever finds Apple's —
    // Homebrew's bin dirs are listed explicitly. Homebrew's versioned formulae
    // (python@3.12) install only `python3.12`, no plain `python3`, hence the scan.
    nonisolated static let homebrewBinDirs = ["/opt/homebrew/bin", "/usr/local/bin"]   // Apple silicon, Intel
    nonisolated static let systemPython = "/usr/bin/python3"
    /// Python minor versions Essentia publishes macOS wheels for; others would try (and fail) a source build.
    nonisolated static let essentiaWheelMinors = 9...14

    struct PythonChoice: Sendable {
        let path: String
        let minor: Int?
        let hasEssentia: Bool
        var isHomebrew: Bool { path != LocalAnalysisCoordinator.systemPython }
        /// Install Essentia here: Homebrew Python with a wheel. Never Apple's system Python.
        var canInstallEssentia: Bool { isHomebrew && minor.map(essentiaWheelMinors.contains) == true }
        var label: String { "Python \(minor.map { "3.\($0)" } ?? "3") (\(isHomebrew ? "Homebrew" : "macOS system"))" }
    }

    /// Homebrew `python3`, then `python3.N` newest first, per bin dir; Apple's last.
    nonisolated static func python3Candidates() -> [String] {
        homebrewBinDirs.flatMap { dir -> [String] in
            let names = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
            let versioned = names
                .compactMap { n in n.hasPrefix("python3.") ? Int(n.dropFirst(8)).map { ($0, n) } : nil }
                .sorted { $0.0 > $1.0 }
                .map(\.1)
            return ((names.contains("python3") ? ["python3"] : []) + versioned).map { "\(dir)/\($0)" }
        } + [systemPython]
    }

    /// First interpreter that already has Essentia (keeps existing setups, including an old
    /// install into Apple's Python); otherwise the first one Essentia can be installed into;
    /// otherwise the first found. Evaluated once — installing a new Python needs a relaunch.
    /// ponytail: probes run on first access (≈50 ms per interpreter, find_spec doesn't import Essentia).
    nonisolated static let python: PythonChoice = {
        choosePython(python3Candidates()
            .filter { FileManager.default.fileExists(atPath: $0) }
            .map(probePython))
    }()

    nonisolated static func choosePython(_ probes: [PythonChoice]) -> PythonChoice {
        probes.first(where: \.hasEssentia)
            ?? probes.first(where: \.canInstallEssentia)
            ?? probes.first
            ?? PythonChoice(path: systemPython, minor: nil, hasEssentia: false)
    }

    nonisolated static var python3Path: String { python.path }

    nonisolated private static func probePython(_ path: String) -> PythonChoice {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = ["-c", "import sys, importlib.util as u; print(sys.version_info.minor, u.find_spec('essentia') is not None)"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        guard (try? proc.run()) != nil else { return PythonChoice(path: path, minor: nil, hasEssentia: false) }
        proc.waitUntilExit()
        let parts = (String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
            .split(separator: " ").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        return PythonChoice(path: path,
                            minor: parts.first.flatMap { Int($0) },
                            hasEssentia: parts.count == 2 && parts[1] == "True")
    }

    /// Shown when Essentia is missing and there's nowhere sensible to install it.
    nonisolated static var noInstallablePythonMessage: String {
        "Essentia needs Homebrew Python 3.\(essentiaWheelMinors.lowerBound)–3.\(essentiaWheelMinors.upperBound) "
        + "(looked in \(homebrewBinDirs.joined(separator: " and "))). "
        + "In Terminal run: brew install python@3.\(essentiaWheelMinors.upperBound) — then quit and reopen VinylHarmonicMix. "
        + "The app won't install packages into macOS's own \(systemPython)."
    }

    // MARK: - Script location

    static let scriptName = "essentia_analyze.py"

    /// Bundled script path, or nil after moving to .failed with a message naming the missing script.
    private func bundledScriptPath() -> String? {
        do { return try BundledScript.path(Self.scriptName) }
        catch { phase = .failed(error.localizedDescription); return nil }
    }

    // MARK: - Analysis phase

    enum Phase: Equatable {
        case idle, analyzing, paused, completed, cancelled
        case failed(String)

        var isIdle: Bool {
            switch self { case .idle, .completed, .cancelled, .failed: return true; default: return false }
        }
    }

    // MARK: - Essentia provisioning state

    enum EssentiaStatus: Equatable {
        case unknown                  // not yet probed
        case testing                  // import test running
        case installed(String)        // version string, e.g. "essentia 2.1-beta6-dev"
        case notInstalled             // import failed → show Install button
        case installing               // pip install running
        case installFailed(String)    // pip failed → show reason
        case testFailed(String)       // python3 not found or other non-import error
    }

    // MARK: - Analysis mode

    enum AnalysisMode { case tracks, files }

    // MARK: - Observable state

    var phase: Phase = .idle
    var currentMode: AnalysisMode = .tracks
    var currentTrackLabel: String = ""
    var totalCount: Int = 0
    var analyzedCount: Int = 0
    var failedCount: Int = 0
    var lastError: String? = nil
    var inScopeFileCount: Int = 0
    var unanalyzedFileCount: Int = 0
    var skippedFolderCount: Int = 0

    var shouldShowPanel: Bool { phase != .idle }

    var analyzedLocalCount: Int {
        (try? context.fetchCount(FetchDescriptor<LocalAudioFeaturesEntity>())) ?? 0
    }

    var confidentCount: Int {
        (try? context.fetchCount(FetchDescriptor<TrackEntity>(
            predicate: #Predicate { $0.fileMatchState == "confident" }
        ))) ?? 0
    }

    var essentiaStatus: EssentiaStatus = .unknown

    // MARK: - Private

    private let context: ModelContext
    private let driveMonitor: DriveMonitor?
    private var scanTask: Task<Void, Never>?
    private var pendingLimit: Int? = nil
    private var pendingPaths: [String]? = nil
    private var pendingReanalyzeBefore: Date? = nil
    /// Fired whenever BPM/key results are written (card badge cache invalidation).
    var onAnalysisDataChanged: (() -> Void)? = nil

    init(context: ModelContext, driveMonitor: DriveMonitor? = nil) {
        self.context = context
        self.driveMonitor = driveMonitor
    }

    /// C3: folders unreachable right now. Files under them are skipped (not failed, not
    /// marked) so a sleeping NAS doesn't poison analysis state; the count is shown in the toolbar.
    private func missingFolders() -> [LibraryFolder] {
        driveMonitor?.refreshAvailability()
        let missing = driveMonitor?.missingFolders ?? []
        skippedFolderCount = missing.count
        return missing
    }

    // MARK: - Analysis controls

    func startAnalysis(limit: Int? = nil) {
        guard phase.isIdle, bundledScriptPath() != nil else { return }
        pendingLimit = limit
        currentMode = .tracks
        phase = .analyzing
        analyzedCount = 0; failedCount = 0; totalCount = 0
        currentTrackLabel = ""; lastError = nil

        scanTask = Task { [weak self] in
            guard let self else { return }
            await self.runAnalysis(limit: limit)
            guard !Task.isCancelled else { return }
            if self.phase == .analyzing { self.phase = .completed }
        }
    }

    /// `paths` scopes the run to exactly those files ("Link folder…"), skipping the artist-folder
    /// filter. `reanalyzeBefore` (with `paths` only) also redoes files analyzed before that date —
    /// a fixed cutoff rather than a flag, so resume after pause skips files this run already redid.
    /// Returns the run's task so a caller can await it; nil when another run is active.
    @discardableResult
    func startFileAnalysis(limit: Int? = nil, paths: [String]? = nil, reanalyzeBefore: Date? = nil) -> Task<Void, Never>? {
        guard phase.isIdle, bundledScriptPath() != nil else { return nil }
        pendingLimit = limit
        pendingPaths = paths
        pendingReanalyzeBefore = reanalyzeBefore
        currentMode = .files
        phase = .analyzing
        analyzedCount = 0; failedCount = 0; totalCount = 0
        currentTrackLabel = ""; lastError = nil

        scanTask = Task { [weak self] in
            guard let self else { return }
            await self.runFileAnalysis(limit: limit, paths: paths, reanalyzeBefore: reanalyzeBefore)
            guard !Task.isCancelled else { return }
            if self.phase == .analyzing { self.phase = .completed }
        }
        return scanTask
    }

    /// Count of in-scope unanalyzed local files without starting analysis.
    /// Uses the same artist-folder token similarity filter as runFileAnalysis.
    /// Called by SyncOrchestrator to surface the pending count before running.
    func pendingFileAnalysisCount() async -> Int {
        let artistNames = ((try? context.fetch(FetchDescriptor<ArtistCreditEntity>())) ?? []).map(\.name)
        let artistTokenSets: [Set<String>] = artistNames.map { name in
            Set(FuzzyMatch.normalize(name).split(separator: " ").map(String.init)).filter { $0.count >= 2 }
        }
        let allFiles = (try? context.fetch(FetchDescriptor<LocalFileEntity>())) ?? []
        let missing = missingFolders()
        let summaries: [LocalFileSummary] = allFiles.compactMap { file in
            guard !file.artistFolder.isEmpty,
                  !missing.contains(where: { $0.contains(path: file.filePath) }) else { return nil }
            return LocalFileSummary(
                id: file.persistentModelID,
                filePath: file.filePath,
                artistFolder: file.artistFolder,
                analyzed: file.bpm > 0 || file.analyzedAt != nil
            )
        }
        return await Task.detached(priority: .utility) {
            summaries.filter { s in
                guard !s.analyzed else { return false }
                let folderTokens = Set(
                    FuzzyMatch.normalizeFolderName(s.artistFolder).split(separator: " ").map(String.init)
                ).filter { $0.count >= 2 }
                return artistTokenSets.contains { artistTokens in
                    let isect = folderTokens.intersection(artistTokens).count
                    let maxN = max(folderTokens.count, artistTokens.count)
                    return maxN > 0 && Double(isect) / Double(maxN) >= 0.7
                }
            }.count
        }.value
    }

    /// Awaitable file analysis for use by SyncOrchestrator.
    /// Runs runFileAnalysis() inline (same filter: unanalyzed in-scope files only) and returns when done.
    /// NEVER re-analyzes already-analyzed files (runFileAnalysis filters bpm > 0 || analyzedAt != nil).
    func startAndAwaitFileAnalysis() async {
        guard phase.isIdle, bundledScriptPath() != nil else { return }
        pendingLimit = nil
        pendingPaths = nil
        pendingReanalyzeBefore = nil
        currentMode = .files
        phase = .analyzing
        analyzedCount = 0; failedCount = 0; totalCount = 0
        currentTrackLabel = ""; lastError = nil

        await runFileAnalysis(limit: nil)
        guard !Task.isCancelled else { return }
        if phase == .analyzing { phase = .completed }
    }

    func startTestBatch() { startAnalysis(limit: 10) }

    func pause() {
        scanTask?.cancel(); scanTask = nil
        phase = .paused
    }

    func resume() {
        guard phase == .paused else { return }
        switch currentMode {
        case .tracks: startAnalysis(limit: pendingLimit)
        case .files:  startFileAnalysis(limit: pendingLimit, paths: pendingPaths, reanalyzeBefore: pendingReanalyzeBefore)
        }
    }

    func cancel() {
        scanTask?.cancel(); scanTask = nil
        phase = .cancelled
    }

    func dismissPanel() {
        phase = .idle
        analyzedCount = 0; failedCount = 0; totalCount = 0
        currentTrackLabel = ""; lastError = nil
    }

    // MARK: - Essentia provisioning

    func testEssentia() {
        essentiaStatus = .testing
        Task {
            essentiaStatus = await Self.probeEssentia()
        }
    }

    func installEssentia() {
        essentiaStatus = .installing
        Task {
            let errorMsg = await Self.runPipInstall()
            if let msg = errorMsg {
                essentiaStatus = .installFailed(msg)
            } else {
                // Install reported success — confirm with an import test
                essentiaStatus = await Self.probeEssentia()
            }
        }
    }

    // MARK: - Probe (import test)
    //
    // Uses python3Path — same binary as the analysis subprocess.
    // Returns .installed / .notInstalled / .testFailed.
    nonisolated private static func probeEssentia() async -> EssentiaStatus {
        await Task.detached(priority: .utility) { () -> EssentiaStatus in
            let python = python3Path

            guard FileManager.default.fileExists(atPath: python) else {
                return .testFailed(
                    "Python 3 not found at \(python). Install Python 3 (e.g. brew install python) then retry."
                )
            }

            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: python)
            proc.arguments = ["-c", "import essentia; print('essentia', essentia.__version__)"]
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = pipe
            do {
                try proc.run()
                proc.waitUntilExit()
            } catch {
                return .testFailed("Cannot run \(python): \(error.localizedDescription)")
            }

            let output = String(
                data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8
            )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            if proc.terminationStatus == 0, !output.isEmpty {
                return .installed(output)
            }
            // ModuleNotFoundError → notInstalled; anything else → testFailed
            if output.contains("ModuleNotFoundError") || output.contains("No module named") {
                return .notInstalled
            }
            return output.isEmpty ? .notInstalled : .testFailed(output)
        }.value
    }

    // MARK: - pip install
    //
    // --user puts Essentia in ~/Library/Python/3.x, leaving Homebrew's own files alone;
    // Homebrew marks its Python externally managed (PEP 668), so pip also needs
    // --break-system-packages even for a --user install.
    nonisolated static let essentiaPipArguments = ["-m", "pip", "install", "--user", "--break-system-packages", "essentia"]
    //
    // Returns nil on success, or an error string on failure.
    nonisolated private static func runPipInstall() async -> String? {
        await Task.detached(priority: .utility) { () -> String? in
            let python = python3Path

            guard Self.python.canInstallEssentia else { return noInstallablePythonMessage }

            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: python)
            proc.arguments = essentiaPipArguments
            let outPipe = Pipe()
            let errPipe = Pipe()
            proc.standardOutput = outPipe
            proc.standardError  = errPipe

            do {
                try proc.run()
            } catch {
                return "Cannot run \(python): \(error.localizedDescription)"
            }

            proc.waitUntilExit()

            if proc.terminationStatus == 0 { return nil }

            // Gather stderr for the failure message; fall back to stdout
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            let stderr = String(data: errData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let stdout = String(data: outData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            // Surface the most useful tail of the error output
            let combined = stderr.isEmpty ? stdout : stderr
            let lines = combined.components(separatedBy: "\n")
            let tail = lines.suffix(6).joined(separator: "\n")

            if combined.contains("No module named pip") || combined.contains("pip: command not found") {
                return "pip not found for \(python). The Python installation may be incomplete."
            }
            return tail.isEmpty ? "pip exited with code \(proc.terminationStatus)" : tail
        }.value
    }

    // MARK: - Analysis loop

    private func runAnalysis(limit: Int?) async {
        let allConfident = (try? context.fetch(FetchDescriptor<TrackEntity>(
            predicate: #Predicate { $0.fileMatchState == "confident" }
        ))) ?? []

        let missing = missingFolders()
        let unanalyzed = allConfident.filter { t in
            guard t.localAudioFeatures == nil, let path = t.primaryLocalFilePath, !path.isEmpty else { return false }
            return !missing.contains { $0.contains(path: path) }
        }
        let scoped = limit.map { Array(unanalyzed.prefix($0)) } ?? unanalyzed

        struct TrackSummary: Sendable {
            let id: PersistentIdentifier
            let filePath: String
            let label: String
        }

        let summaries: [TrackSummary] = scoped.map {
            TrackSummary(id: $0.persistentModelID,
                         filePath: $0.primaryLocalFilePath ?? "",
                         label: "\($0.artistCredit) – \($0.title)")
        }

        totalCount = summaries.count
        if totalCount == 0 { phase = .completed; return }

        // ponytail: batch saves — flush every ~10 tracks or ~1s, whichever comes first,
        // instead of per track. context.save() runs on the main actor and invalidates
        // every live @Query in the visible view, so per-track saving was stuttering
        // scroll in whatever view was on screen during a background analysis run.
        // The Stats header no longer needs per-track saves for live progress (see 1a:
        // it now reads analyzedCount/totalCount directly), so this is safe to relax.
        let chunkSize = 10
        let minFlushInterval: TimeInterval = 1.0
        var saveBuffer: [(PersistentIdentifier, AnalysisResult)] = []
        var lastFlush = Date()

        for (i, summary) in summaries.enumerated() {
            if Task.isCancelled { break }
            currentTrackLabel = summary.label

            let result = await runScript(filePath: summary.filePath)

            switch result {
            case .success(let parsed):
                saveBuffer.append((summary.id, parsed))
            case .failure(let msg):
                failedCount += 1
                print("[LocalAnalysis] ✗ \(summary.label): \(msg)")
            }

            analyzedCount = i + 1

            let isLast = i == summaries.count - 1
            let dueForFlush = saveBuffer.count >= chunkSize
                || Date().timeIntervalSince(lastFlush) >= minFlushInterval
                || isLast
            if !saveBuffer.isEmpty && dueForFlush {
                flushResults(saveBuffer)
                saveBuffer.removeAll()
                lastFlush = Date()
                await Task.yield()
            }
        }

        // Final flush — catches a partial buffer left over from a cancellation (the loop
        // above breaks before the isLast branch can run) or a quit mid-run. No analyzed
        // track is ever left unsaved.
        if !saveBuffer.isEmpty {
            flushResults(saveBuffer)
            saveBuffer.removeAll()
        }
        try? context.save()
        currentTrackLabel = ""
    }

    // MARK: - Script execution

    struct AnalysisResult: Sendable {
        let rawBpm: Double
        let bpm: Double
        let key: String
        let scale: String
        let keyStrength: Double
        let camelot: String
    }

    enum ScriptOutcome: Sendable {
        case success(AnalysisResult)
        case failure(String)
    }

    private func runScript(filePath: String) async -> ScriptOutcome {
        let scriptPath: String
        do { scriptPath = try BundledScript.path(Self.scriptName) }
        catch { return .failure(error.localizedDescription) }
        let python3 = Self.python3Path   // same binary as install + test

        return await Task.detached(priority: .utility) { () -> ScriptOutcome in
            let output: Subprocess.Output
            do {
                output = try await Subprocess.run(python3, arguments: [scriptPath, filePath], timeout: .seconds(120))
            } catch {
                return .failure("Process error: \(error.localizedDescription)")
            }

            guard let raw = String(data: output.stdout, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty else {
                let stderrSnippet = String(data: output.stderr.prefix(1024), encoding: .utf8) ?? ""
                return .failure("Empty output (exit \(output.status)) stderr=\(stderrSnippet)")
            }

            guard let jsonData = raw.data(using: .utf8),
                  let dict = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
            else {
                return .failure("JSON parse failed: \(raw.prefix(120))")
            }

            if let err = dict["error"] as? String { return .failure(err) }

            guard let rawBpm = dict["bpm"] as? Double,
                  let key    = dict["key"] as? String,
                  let scale  = dict["scale"] as? String,
                  let str    = dict["key_strength"] as? Double
            else {
                return .failure("Missing fields: \(raw.prefix(120))")
            }

            let normalizedBpm = Self.normalizeBpm(rawBpm)
            let camelot = CamelotConverter.camelotCode(forNote: key, scale: scale) ?? ""

            return .success(AnalysisResult(
                rawBpm: rawBpm, bpm: normalizedBpm,
                key: key, scale: scale, keyStrength: str, camelot: camelot
            ))
        }.value
    }

    // MARK: - BPM normalization

    nonisolated private static func normalizeBpm(_ raw: Double) -> Double {
        var b = raw
        while b > 0 && b < 90 { b *= 2 }
        while b > 180 { b /= 2 }
        return (b * 100).rounded() / 100
    }

    // MARK: - File analysis

    private struct LocalFileSummary: Sendable {
        let id: PersistentIdentifier
        let filePath: String
        let artistFolder: String
        let analyzed: Bool
    }

    private func runFileAnalysis(limit: Int?, paths: [String]? = nil, reanalyzeBefore: Date? = nil) async {
        let inScope = if let paths { scopedFileSummaries(paths, reanalyzeBefore: reanalyzeBefore) } else { await libraryFileSummaries() }

        let scoped = limit.map { Array(inScope.prefix($0)) } ?? inScope
        totalCount = scoped.count
        if totalCount == 0 { phase = .completed; return }

        // ponytail: batch saves, same cadence/reasoning as runAnalysis above — flush
        // every ~10 files or ~1s instead of per file.
        let chunkSize = 10
        let minFlushInterval: TimeInterval = 1.0
        var saveBuffer: [(PersistentIdentifier, AnalysisResult)] = []
        var lastFlush = Date()

        for (i, summary) in scoped.enumerated() {
            if Task.isCancelled { break }
            let filename = URL(fileURLWithPath: summary.filePath).lastPathComponent
            currentTrackLabel = summary.artistFolder.isEmpty ? filename : "\(summary.artistFolder) — \(filename)"
            let result = await runScript(filePath: summary.filePath)
            switch result {
            case .success(let parsed):
                saveBuffer.append((summary.id, parsed))
            case .failure(let msg):
                failedCount += 1
                print("[FileAnalysis] ✗ \(summary.filePath): \(msg)")
            }

            analyzedCount = i + 1

            let isLast = i == scoped.count - 1
            let dueForFlush = saveBuffer.count >= chunkSize
                || Date().timeIntervalSince(lastFlush) >= minFlushInterval
                || isLast
            if !saveBuffer.isEmpty && dueForFlush {
                flushFileResults(saveBuffer)
                saveBuffer.removeAll()
                lastFlush = Date()
                recomputeFileScope(force: true)
                await Task.yield()
            }
        }

        // Final flush — same cancel/quit safety net as runAnalysis above.
        if !saveBuffer.isEmpty {
            flushFileResults(saveBuffer)
            saveBuffer.removeAll()
        }
        try? context.save()
        currentTrackLabel = ""
        // force: true — files were just analyzed, so the unanalyzed count must refresh
        // even though the total LocalFileEntity row count didn't change.
        recomputeFileScope(force: true)
    }

    /// Unanalyzed files among `paths` (plus those analyzed before `reanalyzeBefore`) — no artist-folder
    /// filter; unreachable library folders still skipped.
    private func scopedFileSummaries(_ paths: [String], reanalyzeBefore: Date? = nil) -> [LocalFileSummary] {
        let files = (try? context.fetch(FetchDescriptor<LocalFileEntity>(
            predicate: #Predicate { paths.contains($0.filePath) }
        ))) ?? []
        let missing = missingFolders()
        return files.compactMap { file in
            let pending = (file.bpm == 0 && file.analyzedAt == nil)
                || reanalyzeBefore.map { cutoff in (file.analyzedAt ?? .distantPast) < cutoff } ?? false
            guard pending,
                  !missing.contains(where: { $0.contains(path: file.filePath) }) else { return nil }
            return LocalFileSummary(id: file.persistentModelID, filePath: file.filePath,
                                    artistFolder: file.artistFolder, analyzed: false)
        }
    }

    private func libraryFileSummaries() async -> [LocalFileSummary] {
        let artistNames = ((try? context.fetch(FetchDescriptor<ArtistCreditEntity>())) ?? []).map(\.name)
        let artistTokenSets: [Set<String>] = artistNames.map { name in
            Set(FuzzyMatch.normalize(name).split(separator: " ").map(String.init)).filter { $0.count >= 2 }
        }

        let allFiles = (try? context.fetch(FetchDescriptor<LocalFileEntity>())) ?? []
        let missing = missingFolders()
        let summaries: [LocalFileSummary] = allFiles.compactMap { file in
            guard !file.artistFolder.isEmpty,
                  !missing.contains(where: { $0.contains(path: file.filePath) }) else { return nil }
            return LocalFileSummary(
                id: file.persistentModelID,
                filePath: file.filePath,
                artistFolder: file.artistFolder,
                analyzed: file.bpm > 0 || file.analyzedAt != nil
            )
        }

        let inScope: [LocalFileSummary] = await Task.detached(priority: .utility) {
            summaries.filter { s in
                guard !s.analyzed else { return false }
                let folderTokens = Set(
                    FuzzyMatch.normalizeFolderName(s.artistFolder).split(separator: " ").map(String.init)
                ).filter { $0.count >= 2 }
                return artistTokenSets.contains { artistTokens in
                    let isect = folderTokens.intersection(artistTokens).count
                    let maxN = max(folderTokens.count, artistTokens.count)
                    return maxN > 0 && Double(isect) / Double(maxN) >= 0.7
                }
            }
        }.value
        return inScope
    }

    private func flushFileResults(_ buffer: [(PersistentIdentifier, AnalysisResult)]) {
        PerfLog.begin("LocalAnalysisCoordinator.flushFileResults(\(buffer.count))")
        for (fileID, result) in buffer {
            guard let file = context.model(for: fileID) as? LocalFileEntity else { continue }
            file.rawBpm          = result.rawBpm
            file.bpm             = result.bpm
            file.key             = result.key
            file.scale           = result.scale
            file.keyStrength     = result.keyStrength
            file.camelot         = result.camelot
            file.analyzedAt      = .now
            file.analyzerVersion = "essentia-2.1b6 degara"
        }
        onAnalysisDataChanged?()
        try? context.save()
        PerfLog.end("LocalAnalysisCoordinator.flushFileResults(\(buffer.count))")
    }

    private var lastFileScopeCount = -1

    /// Recomputes inScopeFileCount/unanalyzedFileCount. Skips the rebuild when the total
    /// LocalFileEntity row count hasn't changed since the last run — callers whose change
    /// doesn't touch that count (e.g. after analyzing existing files) must pass `force: true`.
    func recomputeFileScope(force: Bool = false) {
        let currentFileCount = (try? context.fetchCount(FetchDescriptor<LocalFileEntity>())) ?? 0
        guard force || currentFileCount != lastFileScopeCount else { return }
        lastFileScopeCount = currentFileCount

        let artistNames = ((try? context.fetch(FetchDescriptor<ArtistCreditEntity>())) ?? []).map(\.name)
        let artistTokenSets: [Set<String>] = artistNames.map { name in
            Set(FuzzyMatch.normalize(name).split(separator: " ").map(String.init)).filter { $0.count >= 2 }
        }

        // propertiesToFetch avoids loading each file's waveform blobs (up to ~64 KB/file)
        // just to read four small fields — the main-actor cost this was blocking on.
        var fd = FetchDescriptor<LocalFileEntity>()
        fd.propertiesToFetch = [\.filePath, \.artistFolder, \.bpm, \.analyzedAt]
        let allFiles = (try? context.fetch(fd)) ?? []
        let summaries: [LocalFileSummary] = allFiles.compactMap { file in
            guard !file.artistFolder.isEmpty else { return nil }
            return LocalFileSummary(
                id: file.persistentModelID,
                filePath: file.filePath,
                artistFolder: file.artistFolder,
                analyzed: file.bpm > 0 || file.analyzedAt != nil
            )
        }

        Task.detached(priority: .utility) { [weak self] in
            var inScopeCount = 0
            var unanalyzedCount = 0
            for s in summaries {
                let folderTokens = Set(
                    FuzzyMatch.normalizeFolderName(s.artistFolder).split(separator: " ").map(String.init)
                ).filter { $0.count >= 2 }
                let matches = artistTokenSets.contains { artistTokens in
                    let isect = folderTokens.intersection(artistTokens).count
                    let maxN = max(folderTokens.count, artistTokens.count)
                    return maxN > 0 && Double(isect) / Double(maxN) >= 0.7
                }
                if matches {
                    inScopeCount += 1
                    if !s.analyzed { unanalyzedCount += 1 }
                }
            }
            // Bind finished values: the hop must not capture the vars it was still mutating.
            let (inScope, unanalyzed) = (inScopeCount, unanalyzedCount)
            await MainActor.run { [weak self] in
                self?.inScopeFileCount = inScope
                self?.unanalyzedFileCount = unanalyzed
            }
        }
    }

    // MARK: - Single-file analysis (triggered from detail popup on manual file assignment)

    func analyzeSingleFile(path: String) async -> Bool {
        guard bundledScriptPath() != nil else { return false }
        let outcome = await runScript(filePath: path)
        guard case .success(let result) = outcome else {
            if case .failure(let msg) = outcome {
                print("[LocalAnalysis] Single-file ✗ \(path): \(msg)")
            }
            return false
        }
        var fd = FetchDescriptor<LocalFileEntity>(predicate: #Predicate { $0.filePath == path })
        fd.fetchLimit = 1
        guard let file = try? context.fetch(fd).first else { return false }
        file.rawBpm          = result.rawBpm
        file.bpm             = result.bpm
        file.key             = result.key
        file.scale           = result.scale
        file.keyStrength     = result.keyStrength
        file.camelot         = result.camelot
        file.analyzedAt      = .now
        file.analyzerVersion = "essentia-2.1b6 degara"
        onAnalysisDataChanged?()
        try? context.save()
        return true
    }

    // MARK: - Write-back (tracks)

    private func flushResults(_ buffer: [(PersistentIdentifier, AnalysisResult)]) {
        PerfLog.begin("LocalAnalysisCoordinator.flushResults(\(buffer.count))")
        for (trackID, result) in buffer {
            guard let track = context.model(for: trackID) as? TrackEntity else { continue }

            let features = track.localAudioFeatures ?? {
                let f = LocalAudioFeaturesEntity()
                context.insert(f)
                f.track = track
                track.localAudioFeatures = f
                return f
            }()

            features.rawBpm          = result.rawBpm
            features.bpm             = result.bpm
            features.key             = result.key
            features.scale           = result.scale
            features.keyStrength     = result.keyStrength
            features.camelot         = result.camelot
            features.analyzedAt      = .now
            features.analyzerVersion = "essentia-2.1b6 degara"
        }
        onAnalysisDataChanged?()
        try? context.save()
        PerfLog.end("LocalAnalysisCoordinator.flushResults(\(buffer.count))")
    }
}
