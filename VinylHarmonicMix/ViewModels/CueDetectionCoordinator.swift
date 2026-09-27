import Foundation
import SwiftData

@MainActor
@Observable
final class CueDetectionCoordinator {

    // MARK: - Script location + version
    static let scriptPath: String =
        "/Users/ghailen/Desktop/MacOS Project/VinylHarmonicMix/Scripts/essentia_cue.py"

    // Bump this string whenever the detection algorithm changes.
    // Files whose cueAnalyzerVersion != currentCueVersion re-qualify for detection.
    static let currentCueVersion = "v3-fourtofloor"

    // MARK: - Scope
    enum CueDetectionScope { case matched, unmatched, all }

    // MARK: - Phase
    enum Phase: Equatable {
        case idle, detecting, paused, completed, cancelled
        case failed(String)

        var isIdle: Bool {
            switch self { case .idle, .completed, .cancelled: return true; default: return false }
        }
    }

    // MARK: - Observable state
    var phase: Phase = .idle
    var currentFileLabel: String = ""
    var totalCount: Int = 0
    var processedCount: Int = 0
    var detectedCount: Int = 0
    var skippedCount: Int = 0
    var failedCount: Int = 0
    var skippedFolderCount: Int = 0

    var shouldShowPanel: Bool { phase != .idle }

    // MARK: - Private
    private let context: ModelContext
    private let driveMonitor: DriveMonitor?
    private var scanTask: Task<Void, Never>?
    private var pendingScope: CueDetectionScope = .all
    private var pendingLimit: Int? = nil

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

    // MARK: - Controls

    func startDetection(scope: CueDetectionScope = .all, limit: Int? = nil) {
        guard phase.isIdle else { return }
        pendingScope = scope
        pendingLimit = limit
        phase = .detecting
        processedCount = 0; detectedCount = 0; skippedCount = 0; failedCount = 0
        totalCount = 0; currentFileLabel = ""

        scanTask = Task { [weak self] in
            guard let self else { return }
            await self.runDetection(scope: scope, limit: limit)
            guard !Task.isCancelled else { return }
            if self.phase == .detecting { self.phase = .completed }
        }
    }

    func startDetection(filePath: String) {
        guard phase.isIdle else { return }
        phase = .detecting
        currentFileLabel = URL(fileURLWithPath: filePath).lastPathComponent
        totalCount = 1; processedCount = 0
        detectedCount = 0; skippedCount = 0; failedCount = 0

        scanTask = Task { [weak self] in
            guard let self else { return }

            var descriptor = FetchDescriptor<LocalFileEntity>(
                predicate: #Predicate { $0.filePath == filePath }
            )
            descriptor.fetchLimit = 1
            guard let file = (try? self.context.fetch(descriptor))?.first else {
                self.phase = .failed("No LocalFileEntity found for \(filePath)")
                return
            }
            let fileID = file.persistentModelID

            let outcome = await self.runCueScriptSafe(filePath: filePath)
            guard !Task.isCancelled else { return }

            switch outcome {
            case .success(let result):
                self.flushCueResults([(fileID, result)])
                if result.switchPoints.isEmpty && result.structuralPoints.isEmpty {
                    self.skippedCount = 1
                } else {
                    self.detectedCount = 1
                }
            case .failure(let msg):
                self.failedCount = 1
                print("[CueDetection] ✗ \(filePath): \(msg)")
            }

            self.processedCount = 1
            if !Task.isCancelled { self.phase = .completed }
        }
    }

    func pause() {
        scanTask?.cancel(); scanTask = nil
        phase = .paused
    }

    func resume() {
        guard phase == .paused else { return }
        startDetection(scope: pendingScope, limit: pendingLimit)
    }

    func cancel() {
        scanTask?.cancel(); scanTask = nil
        phase = .cancelled
    }

    func dismissPanel() {
        phase = .idle
        processedCount = 0; detectedCount = 0; skippedCount = 0; failedCount = 0
        totalCount = 0; currentFileLabel = ""
    }

    // MARK: - Detection loop

    private struct FileSummary: Sendable {
        let id: PersistentIdentifier
        let filePath: String
        let label: String
    }

    private func runDetection(scope: CueDetectionScope, limit: Int?) async {
        let allFiles = (try? context.fetch(FetchDescriptor<LocalFileEntity>())) ?? []
        let scopeMatches: (LocalFileEntity) -> Bool
        switch scope {
        case .matched:   scopeMatches = { $0.matchMethod != "unmatched" }
        case .unmatched: scopeMatches = { $0.matchMethod == "unmatched" }
        case .all:       scopeMatches = { _ in true }
        }
        let missing = missingFolders()
        let candidates = allFiles.filter { file in
            !missing.contains { $0.contains(path: file.filePath) }
        }.filter {
            $0.bpm > 0
            && !$0.filePath.isEmpty
            && ($0.cueAnalyzedAt == nil || $0.cueAnalyzerVersion != Self.currentCueVersion)
            && scopeMatches($0)
        }
        let scoped = limit.map { Array(candidates.prefix($0)) } ?? candidates

        let summaries: [FileSummary] = scoped.map {
            FileSummary(
                id: $0.persistentModelID,
                filePath: $0.filePath,
                label: URL(fileURLWithPath: $0.filePath).lastPathComponent
            )
        }

        totalCount = summaries.count
        if totalCount == 0 { phase = .completed; return }

        let chunkSize = 25
        var saveBuffer: [(PersistentIdentifier, CueScriptResult)] = []

        for (i, summary) in summaries.enumerated() {
            if Task.isCancelled { break }
            currentFileLabel = summary.label

            let outcome = await runCueScript(filePath: summary.filePath)
            switch outcome {
            case .success(let result):
                saveBuffer.append((summary.id, result))
                if result.switchPoints.isEmpty && result.structuralPoints.isEmpty {
                    skippedCount += 1
                } else {
                    detectedCount += 1
                }
            case .failure(let msg):
                failedCount += 1
                print("[CueDetection] ✗ \(summary.filePath): \(msg)")
            }

            processedCount = i + 1

            if saveBuffer.count >= chunkSize || i == summaries.count - 1 {
                flushCueResults(saveBuffer)
                saveBuffer.removeAll()
                await Task.yield()
            }
        }

        try? context.save()
        currentFileLabel = ""
    }

    // MARK: - Script execution

    struct CueScriptResult: Sendable {
        struct SwitchPoint: Sendable {
            let timeSec: Double
            let feature: String
            let novelty: Double
            let beatIndex: Int
        }
        struct StructuralPoint: Sendable {
            let timeSec: Double
            let novelty: Double
            let beatIndex: Int
            let energyDirection: String
            let energyDelta: Double
            let source: String
        }
        let switchPoints: [SwitchPoint]
        let structuralPoints: [StructuralPoint]
        let fourToFloor: Bool
        let kickRegularity: Double
    }

    enum ScriptOutcome: Sendable {
        case success(CueScriptResult)
        case failure(String)
    }

    private func runCueScript(filePath: String) async -> ScriptOutcome {
        let scriptPath = Self.scriptPath
        let python3 = LocalAnalysisCoordinator.python3Path

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

            let rawSwitch = dict["switch_points"] as? [[String: Any]] ?? []
            let switchPoints: [CueScriptResult.SwitchPoint] = rawSwitch.compactMap { sp in
                guard let t = sp["time_sec"] as? Double,
                      let f = sp["feature"] as? String,
                      let n = sp["novelty"] as? Double,
                      let b = sp["beat_index"] as? Int else { return nil }
                return CueScriptResult.SwitchPoint(timeSec: t, feature: f, novelty: n, beatIndex: b)
            }

            let rawStruct = dict["structural_points"] as? [[String: Any]] ?? []
            let structuralPoints: [CueScriptResult.StructuralPoint] = rawStruct.compactMap { sp in
                guard let t = sp["time_sec"] as? Double,
                      let n = sp["novelty"] as? Double,
                      let b = sp["beat_index"] as? Int else { return nil }
                let dir    = sp["energy_direction"] as? String ?? ""
                let delta  = sp["energy_delta"]     as? Double ?? 0.0
                let source = sp["source"]           as? String ?? "energy"
                return CueScriptResult.StructuralPoint(timeSec: t, novelty: n, beatIndex: b,
                                                       energyDirection: dir, energyDelta: delta,
                                                       source: source)
            }

            let fourToFloor   = dict["four_to_floor"]   as? Bool   ?? false
            let kickRegularity = dict["kick_regularity"] as? Double ?? 0.0

            return .success(CueScriptResult(switchPoints: switchPoints,
                                            structuralPoints: structuralPoints,
                                            fourToFloor: fourToFloor,
                                            kickRegularity: kickRegularity))
        }.value
    }

    private func runCueScriptSafe(filePath: String) async -> ScriptOutcome {
        let scriptPath = Self.scriptPath
        let python3 = LocalAnalysisCoordinator.python3Path

        return await Task.detached(priority: .utility) { () -> ScriptOutcome in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: python3)
            process.arguments = [scriptPath, filePath]

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError  = stderrPipe

            var stdoutData = Data()
            var stderrData = Data()
            let stdoutLock = NSLock()
            let stderrLock = NSLock()

            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if !chunk.isEmpty { stdoutLock.lock(); stdoutData.append(chunk); stdoutLock.unlock() }
            }
            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if !chunk.isEmpty { stderrLock.lock(); stderrData.append(chunk); stderrLock.unlock() }
            }

            do { try process.run() } catch {
                return .failure("Process error: \(error.localizedDescription)")
            }

            let timeoutSeconds: TimeInterval = 120
            let startTime = Date()
            while process.isRunning {
                if Date().timeIntervalSince(startTime) > timeoutSeconds {
                    process.terminate()
                    Thread.sleep(forTimeInterval: 1)
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                    break
                }
                Thread.sleep(forTimeInterval: 0.1)
            }
            process.waitUntilExit()

            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            let finalOut = stdoutPipe.fileHandleForReading.availableData
            if !finalOut.isEmpty { stdoutLock.lock(); stdoutData.append(finalOut); stdoutLock.unlock() }
            let finalErr = stderrPipe.fileHandleForReading.availableData
            if !finalErr.isEmpty { stderrLock.lock(); stderrData.append(finalErr); stderrLock.unlock() }

            guard let raw = String(data: stdoutData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty else {
                let stderrSnippet = String(data: stderrData.prefix(1024), encoding: .utf8) ?? ""
                return .failure("Empty output (exit \(process.terminationStatus)) stderr=\(stderrSnippet)")
            }

            guard let jsonData = raw.data(using: .utf8),
                  let dict = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
            else {
                return .failure("JSON parse failed: \(raw.prefix(120))")
            }

            if let err = dict["error"] as? String { return .failure(err) }

            let rawSwitch = dict["switch_points"] as? [[String: Any]] ?? []
            let switchPoints: [CueScriptResult.SwitchPoint] = rawSwitch.compactMap { sp in
                guard let t = sp["time_sec"] as? Double,
                      let f = sp["feature"] as? String,
                      let n = sp["novelty"] as? Double,
                      let b = sp["beat_index"] as? Int else { return nil }
                return CueScriptResult.SwitchPoint(timeSec: t, feature: f, novelty: n, beatIndex: b)
            }

            let rawStruct = dict["structural_points"] as? [[String: Any]] ?? []
            let structuralPoints: [CueScriptResult.StructuralPoint] = rawStruct.compactMap { sp in
                guard let t = sp["time_sec"] as? Double,
                      let n = sp["novelty"] as? Double,
                      let b = sp["beat_index"] as? Int else { return nil }
                let dir    = sp["energy_direction"] as? String ?? ""
                let delta  = sp["energy_delta"]     as? Double ?? 0.0
                let source = sp["source"]           as? String ?? "energy"
                return CueScriptResult.StructuralPoint(timeSec: t, novelty: n, beatIndex: b,
                                                        energyDirection: dir, energyDelta: delta,
                                                        source: source)
            }

            let fourToFloor    = dict["four_to_floor"]    as? Bool   ?? false
            let kickRegularity = dict["kick_regularity"] as? Double ?? 0.0

            return .success(CueScriptResult(switchPoints: switchPoints,
                                             structuralPoints: structuralPoints,
                                             fourToFloor: fourToFloor,
                                             kickRegularity: kickRegularity))
        }.value
    }

    // MARK: - Write-back

    private func flushCueResults(_ buffer: [(PersistentIdentifier, CueScriptResult)]) {
        for (fileID, result) in buffer {
            guard let file = context.model(for: fileID) as? LocalFileEntity else { continue }

            // Clear auto cue rows before writing new ones; preserve manual cues
            for existing in file.cuePoints where !existing.isManual { context.delete(existing) }

            for sp in result.switchPoints {
                let cue = CuePointEntity()
                cue.timeSec         = sp.timeSec
                cue.feature         = sp.feature
                cue.novelty         = sp.novelty
                cue.beatIndex       = sp.beatIndex
                cue.type            = "switch_in"
                cue.energyDirection = ""
                cue.createdAt       = .now
                cue.localFile       = file
                context.insert(cue)
                file.cuePoints.append(cue)
            }

            for sp in result.structuralPoints {
                let cue = CuePointEntity()
                cue.timeSec         = sp.timeSec
                cue.feature         = "energy"
                cue.novelty         = sp.novelty
                cue.beatIndex       = sp.beatIndex
                cue.type            = "structural"
                cue.energyDirection = sp.energyDirection
                cue.energyDelta     = sp.energyDelta
                cue.source          = sp.source
                cue.createdAt       = .now
                cue.localFile       = file
                context.insert(cue)
                file.cuePoints.append(cue)
            }

            file.fourToFloor        = result.fourToFloor
            file.kickRegularity     = result.kickRegularity
            file.cueAnalyzedAt      = .now
            file.cueAnalyzerVersion = Self.currentCueVersion
        }
        try? context.save()
    }
}
