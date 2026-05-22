import Foundation
import SwiftData

@MainActor
@Observable
final class LocalAnalysisCoordinator {

    // MARK: - Single source of truth: python3 path
    //
    // Both the analysis subprocess and the pip installer use this exact path.
    // Preference order: Homebrew arm64 → Homebrew Intel → which python3 → system fallback.
    // Evaluated once at first access; FileManager.fileExists is safe from any thread.
    nonisolated static let python3Path: String = {
        let candidates = [
            "/opt/homebrew/bin/python3",   // Homebrew on Apple Silicon
            "/usr/local/bin/python3",       // Homebrew on Intel
        ]
        for p in candidates where FileManager.default.fileExists(atPath: p) {
            return p
        }
        // which python3 as last resort
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        proc.arguments = ["python3"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        try? proc.run()
        proc.waitUntilExit()
        let found = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return found.isEmpty ? "/usr/bin/python3" : found
    }()

    // MARK: - Script location

    static let scriptPath: String =
        "/Users/ghailen/Desktop/MacOS Project/VinylHarmonicMix/Scripts/essentia_analyze.py"

    // MARK: - Analysis phase

    enum Phase: Equatable {
        case idle, analyzing, paused, completed, cancelled
        case failed(String)

        var isIdle: Bool {
            switch self { case .idle, .completed, .cancelled: return true; default: return false }
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

    // MARK: - Observable state

    var phase: Phase = .idle
    var currentTrackLabel: String = ""
    var totalCount: Int = 0
    var analyzedCount: Int = 0
    var failedCount: Int = 0
    var lastError: String? = nil

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
    private var scanTask: Task<Void, Never>?
    private var pendingLimit: Int? = nil

    init(context: ModelContext) { self.context = context }

    // MARK: - Analysis controls

    func startAnalysis(limit: Int? = nil) {
        guard phase.isIdle else { return }
        pendingLimit = limit
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

    func startTestBatch() { startAnalysis(limit: 10) }

    func pause() {
        scanTask?.cancel(); scanTask = nil
        phase = .paused
    }

    func resume() {
        guard phase == .paused else { return }
        startAnalysis(limit: pendingLimit)
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
    // Returns nil on success, or an error string on failure.
    nonisolated private static func runPipInstall() async -> String? {
        await Task.detached(priority: .utility) { () -> String? in
            let python = python3Path

            guard FileManager.default.fileExists(atPath: python) else {
                return "Python 3 not found at \(python). Install Python 3 via Homebrew first."
            }

            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: python)
            proc.arguments = ["-m", "pip", "install", "--break-system-packages", "essentia"]
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

        let unanalyzed = allConfident.filter {
            $0.localAudioFeatures == nil && ($0.primaryLocalFilePath ?? "").isEmpty == false
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

        let chunkSize = 25
        var saveBuffer: [(PersistentIdentifier, AnalysisResult)] = []

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

            if saveBuffer.count >= chunkSize || i == summaries.count - 1 {
                flushResults(saveBuffer)
                saveBuffer.removeAll()
                await Task.yield()
            }
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
        let scriptPath = Self.scriptPath
        let python3 = Self.python3Path   // same binary as install + test

        return await Task.detached(priority: .utility) { () -> ScriptOutcome in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: python3)
            process.arguments = [scriptPath, filePath]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()

            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                return .failure("Process error: \(error.localizedDescription)")
            }

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let raw = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty else {
                return .failure("Empty output (exit \(process.terminationStatus))")
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

    // MARK: - Write-back

    private func flushResults(_ buffer: [(PersistentIdentifier, AnalysisResult)]) {
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
        try? context.save()
    }
}
