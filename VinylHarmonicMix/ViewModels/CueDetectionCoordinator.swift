import Foundation
import SwiftData

@MainActor
@Observable
final class CueDetectionCoordinator {

    // MARK: - Script location
    static let scriptPath: String =
        "/Users/ghailen/Desktop/MacOS Project/VinylHarmonicMix/Scripts/essentia_cue.py"

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

    var shouldShowPanel: Bool { phase != .idle }

    // MARK: - Private
    private let context: ModelContext
    private var scanTask: Task<Void, Never>?
    private var pendingLimit: Int? = nil

    init(context: ModelContext) { self.context = context }

    // MARK: - Controls

    func startDetection(limit: Int? = nil) {
        guard phase.isIdle else { return }
        pendingLimit = limit
        phase = .detecting
        processedCount = 0; detectedCount = 0; skippedCount = 0; failedCount = 0
        totalCount = 0; currentFileLabel = ""

        scanTask = Task { [weak self] in
            guard let self else { return }
            await self.runDetection(limit: limit)
            guard !Task.isCancelled else { return }
            if self.phase == .detecting { self.phase = .completed }
        }
    }

    func pause() {
        scanTask?.cancel(); scanTask = nil
        phase = .paused
    }

    func resume() {
        guard phase == .paused else { return }
        startDetection(limit: pendingLimit)
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

    private func runDetection(limit: Int?) async {
        let allFiles = (try? context.fetch(FetchDescriptor<LocalFileEntity>())) ?? []
        let candidates = allFiles.filter { $0.bpm > 0 && $0.cueAnalyzedAt == nil && !$0.filePath.isEmpty }
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
                if result.switchPoints.isEmpty { skippedCount += 1 } else { detectedCount += 1 }
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
        let switchPoints: [SwitchPoint]
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

            let rawPoints = dict["switch_points"] as? [[String: Any]] ?? []
            let switchPoints: [CueScriptResult.SwitchPoint] = rawPoints.compactMap { sp in
                guard let t = sp["time_sec"] as? Double,
                      let f = sp["feature"] as? String,
                      let n = sp["novelty"] as? Double,
                      let b = sp["beat_index"] as? Int else { return nil }
                return CueScriptResult.SwitchPoint(timeSec: t, feature: f, novelty: n, beatIndex: b)
            }

            return .success(CueScriptResult(switchPoints: switchPoints))
        }.value
    }

    // MARK: - Write-back

    private func flushCueResults(_ buffer: [(PersistentIdentifier, CueScriptResult)]) {
        for (fileID, result) in buffer {
            guard let file = context.model(for: fileID) as? LocalFileEntity else { continue }

            for existing in file.cuePoints { context.delete(existing) }

            for sp in result.switchPoints {
                let cue = CuePointEntity()
                cue.timeSec   = sp.timeSec
                cue.feature   = sp.feature
                cue.novelty   = sp.novelty
                cue.beatIndex = sp.beatIndex
                cue.createdAt = .now
                cue.localFile = file
                context.insert(cue)
                file.cuePoints.append(cue)
            }

            file.cueAnalyzedAt = .now
        }
        try? context.save()
    }
}
