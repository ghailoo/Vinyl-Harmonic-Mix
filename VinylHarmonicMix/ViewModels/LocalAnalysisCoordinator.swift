import Foundation
import SwiftData

@MainActor
@Observable
final class LocalAnalysisCoordinator {

    // MARK: - Script location

    // Absolute path to essentia_analyze.py — update if the project moves.
    static let scriptPath: String = {
        // Resolve relative to the app bundle's parent directory at runtime.
        // During dev the bundle lives inside DerivedData; the script lives in
        // <project_root>/Scripts/. Fall back to a hardcoded dev path if needed.
        let bundleDir = Bundle.main.bundleURL
            .deletingLastPathComponent()  // .app
            .deletingLastPathComponent()  // Debug/
            .deletingLastPathComponent()  // Products/
            .deletingLastPathComponent()  // Build/
            .deletingLastPathComponent()  // DerivedData/<…>/Build/
        let derived = bundleDir
            .appendingPathComponent("SourcePackages") // doesn't exist — just a probe
        _ = derived
        // Best-effort: try known dev path first, then relative to bundle
        let devPath = "/Users/ghailen/Desktop/MacOS Project/VinylHarmonicMix/Scripts/essentia_analyze.py"
        return devPath
    }()

    private static let python3Path = "/opt/homebrew/bin/python3"

    // MARK: - Phase

    enum Phase: Equatable {
        case idle, analyzing, paused, completed, cancelled
        case failed(String)

        var isIdle: Bool {
            switch self { case .idle, .completed, .cancelled: return true; default: return false }
        }
        var isActive: Bool {
            switch self { case .analyzing, .paused: return true; default: return false }
        }
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

    // MARK: - Essentia test state (for Settings)

    enum EssentiaTestStatus: Equatable {
        case idle, testing
        case success(String)  // e.g. "essentia 2.1-beta6-dev"
        case failure(String)
    }

    var essentiaTestStatus: EssentiaTestStatus = .idle

    // MARK: - Private

    private let context: ModelContext
    private var scanTask: Task<Void, Never>?
    private var pendingLimit: Int? = nil

    init(context: ModelContext) { self.context = context }

    // MARK: - Controls

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

    // MARK: - Essentia availability test

    func testEssentia() {
        essentiaTestStatus = .testing
        Task {
            let result = await Self.runEssentiaTest()
            essentiaTestStatus = result
        }
    }

    private static func runEssentiaTest() async -> EssentiaTestStatus {
        await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: python3Path)
            process.arguments = ["-c", "import essentia; print('essentia', essentia.__version__)"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            do {
                try process.run()
                process.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if process.terminationStatus == 0, !output.isEmpty {
                    return EssentiaTestStatus.success(output)
                } else {
                    return EssentiaTestStatus.failure(output.isEmpty ? "No output" : output)
                }
            } catch {
                return EssentiaTestStatus.failure(error.localizedDescription)
            }
        }.value
    }

    // MARK: - Analysis loop

    private func runAnalysis(limit: Int?) async {
        // Snapshot confident tracks that haven't been analyzed yet, as Sendable summaries.
        let allConfident = (try? context.fetch(FetchDescriptor<TrackEntity>(
            predicate: #Predicate { $0.fileMatchState == "confident" }
        ))) ?? []

        // Exclude already-analyzed
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

        // Process with concurrency cap of 2 to avoid hammering SMB
        let chunkSize = 25
        var saveBuffer: [(PersistentIdentifier, AnalysisResult)] = []

        // Serial processing — SMB + CPU-bound decoding; no benefit to racing reads
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

            // Flush every 25
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
        let python3 = Self.python3Path

        return await Task.detached(priority: .utility) { () -> ScriptOutcome in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: python3)
            process.arguments = [scriptPath, filePath]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()  // suppress essentia's stderr noise

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

            if let err = dict["error"] as? String {
                return .failure(err)
            }

            guard let rawBpm = dict["bpm"] as? Double,
                  let key    = dict["key"] as? String,
                  let scale  = dict["scale"] as? String,
                  let str    = dict["key_strength"] as? Double
            else {
                return .failure("Missing fields in JSON: \(raw.prefix(120))")
            }

            let normalizedBpm = Self.normalizeBpm(rawBpm)
            let camelot = CamelotConverter.camelotCode(forNote: key, scale: scale) ?? ""

            return .success(AnalysisResult(
                rawBpm: rawBpm,
                bpm: normalizedBpm,
                key: key,
                scale: scale,
                keyStrength: str,
                camelot: camelot
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

            // Upsert: reuse existing entity if present
            let features = track.localAudioFeatures ?? {
                let f = LocalAudioFeaturesEntity()
                context.insert(f)
                f.track = track
                track.localAudioFeatures = f
                return f
            }()

            features.rawBpm         = result.rawBpm
            features.bpm            = result.bpm
            features.key            = result.key
            features.scale          = result.scale
            features.keyStrength    = result.keyStrength
            features.camelot        = result.camelot
            features.analyzedAt     = .now
            features.analyzerVersion = "essentia-2.1b6 degara"

            analyzedCount += 0  // already incremented in loop; just trigger a save batch
        }
        try? context.save()
    }
}
