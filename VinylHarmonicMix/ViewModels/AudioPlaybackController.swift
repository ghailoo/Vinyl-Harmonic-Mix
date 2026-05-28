import AVFoundation
import Foundation
import SwiftData

@MainActor
@Observable
final class AudioPlaybackController {

    // MARK: - Public playback state
    // These always reflect the ACTIVE source (active deck or single player),
    // so all 6 app-wide consumers (SetLibraryView, CollectionDetailView, etc.)
    // keep working with zero changes.

    private(set) var currentFilePath: String? = nil
    private(set) var isPlaying: Bool = false
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    private(set) var playbackErrors: [String: String] = [:]
    private(set) var playbackFinishedCount: Int = 0

    var volume: Double = 1.0 {
        didSet {
            let v = Float(volume)
            player?.volume      = v
            deckAPlayer?.volume = v
            deckBPlayer?.volume = v
        }
    }

    // MARK: - Waveform state (unchanged)

    private(set) var waveformCache: [String: [Float]] = [:]
    private(set) var waveformColorsCache: [String: Data] = [:]
    private(set) var loadingWaveformPaths: Set<String> = []
    private(set) var failedWaveformPaths: Set<String> = []

    enum WaveformState {
        case idle, loading, failed
        case ready([Float])
    }

    // MARK: - Persistent-cache access (injected at init by VinylHarmonicMixApp)

    var modelContainer: ModelContainer? = nil

    init(modelContainer: ModelContainer? = nil) {
        self.modelContainer = modelContainer
    }

    // MARK: - Mix-mode deck API

    enum Deck { case A, B }

    // MARK: - Private — source tracking

    private enum ActiveSource {
        case single, deckA, deckB
    }
    private var activeSource: ActiveSource = .single

    // The player currently driving the flat interface.
    private var activePlayer: AVAudioPlayer? {
        switch activeSource {
        case .single: return player
        case .deckA:  return deckAPlayer
        case .deckB:  return deckBPlayer
        }
    }

    // MARK: - Private — single-track player (collection cards, SetLibrary, etc.)

    private var player: AVAudioPlayer?
    private var playerDelegate: PlayerDelegate?
    private var ramLoadTask: Task<Void, Never>?

    // MARK: - Private — Deck A (persistent "Now Playing" slot)

    private var deckAPlayer: AVAudioPlayer?
    private var deckAFilePath: String?
    private var deckADelegate: PlayerDelegate?
    private var deckALoadTask: Task<Void, Never>?

    // MARK: - Private — Deck B (persistent "Next Up / candidate" slot)

    private var deckBPlayer: AVAudioPlayer?
    private var deckBFilePath: String?
    private var deckBDelegate: PlayerDelegate?
    private var deckBLoadTask: Task<Void, Never>?

    nonisolated private static let maxRAMAudioBytes = 200 * 1_048_576

    private var timer: Timer?

    // MARK: - Controls

    func play(filePath: String) {

        // ── Toggle: same file is already the active track ────────────────────
        if currentFilePath == filePath {
            if isPlaying {
                activePlayer?.pause()
                stopTimer()
                isPlaying = false
            } else {
                activePlayer?.play()
                startTimer()
                isPlaying = true
                playbackErrors.removeValue(forKey: filePath)
            }
            return
        }

        // ── Deck A is loaded with this file — instant switch ─────────────────
        if filePath == deckAFilePath, let deckA = deckAPlayer {
            pauseCurrentActive()          // pauses other source, holds its position
            activeSource    = .deckA
            currentFilePath = filePath
            duration        = deckA.duration
            currentTime     = deckA.currentTime   // resume from held position
            deckA.volume    = Float(volume)
            deckA.play()
            isPlaying = true
            startTimer()
            playbackErrors.removeValue(forKey: filePath)
            return
        }

        // ── Deck B is loaded with this file — instant switch ─────────────────
        if filePath == deckBFilePath, let deckB = deckBPlayer {
            pauseCurrentActive()
            activeSource    = .deckB
            currentFilePath = filePath
            duration        = deckB.duration
            currentTime     = deckB.currentTime
            deckB.volume    = Float(volume)
            deckB.play()
            isPlaying = true
            startTimer()
            playbackErrors.removeValue(forKey: filePath)
            return
        }

        // ── New file not in either deck — existing single-player behaviour ────
        // Deck players keep their positions (paused, not stopped).
        pauseCurrentActive()
        activeSource = .single
        stopSinglePlayer()
        currentFilePath = filePath
        playbackErrors.removeValue(forKey: filePath)

        let url = URL(fileURLWithPath: filePath)

        // Fast path: Track B was fully preloaded and this new file matches it.
        // (Handles the case where loadDeck(.B) completed but deckBFilePath check
        //  above missed because deckBPlayer was nil when loadDeck started.)
        // — deliberately not repeated here; covered by the deckB check above.

        do {
            let p = try AVAudioPlayer(contentsOf: url)
            let delegate = PlayerDelegate()
            delegate.owner = self
            p.delegate  = delegate
            p.volume    = Float(volume)
            p.prepareToPlay()
            p.play()
            player         = p
            playerDelegate = delegate
            duration       = p.duration
            currentTime    = 0
            isPlaying      = true
            startTimer()
        } catch {
            playbackErrors[filePath] = error.localizedDescription
            player = nil; playerDelegate = nil
            isPlaying = false; duration = 0; currentTime = 0
        }

        loadWaveformIfNeeded(filePath: filePath)
        startRAMLoad(filePath: filePath, url: url)
    }

    func pause() {
        activePlayer?.pause()
        stopTimer()
        isPlaying = false
    }

    func stop() {
        stopSinglePlayer()
        // Pause deck players so they hold their positions.
        deckAPlayer?.pause()
        deckBPlayer?.pause()
        stopTimer()
        isPlaying       = false
        currentFilePath = nil
        currentTime     = 0
        duration        = 0
        activeSource    = .single
    }

    func seek(toFraction fraction: Double) {
        guard let p = activePlayer, duration > 0 else { return }
        let clamped = max(0, min(1, fraction))
        p.currentTime = clamped * p.duration
        currentTime   = p.currentTime
    }

    // MARK: - Deck management (Mix mode)

    /// Assign a file to a deck slot and preload it into RAM so play is instant.
    /// No-op if the slot already holds the same file. Does NOT start playback.
    func loadDeck(_ deck: Deck, filePath: String) {
        guard !filePath.isEmpty else { return }
        let current = deck == .A ? deckAFilePath : deckBFilePath
        guard current != filePath else { return }   // already loaded — nothing to do

        cancelDeckLoad(deck)
        if deck == .A {
            deckAPlayer = nil; deckADelegate = nil; deckAFilePath = filePath
        } else {
            deckBPlayer = nil; deckBDelegate = nil; deckBFilePath = filePath
        }

        let url = URL(fileURLWithPath: filePath)

        let task = Task.detached(priority: .background) { [weak self] in
            let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            guard fileSize > 0,
                  fileSize <= AudioPlaybackController.maxRAMAudioBytes else { return }

            // Brief pause so any active-track NAS read can finish first.
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }

            guard let fh = try? FileHandle(forReadingFrom: url) else { return }
            var chunks: [Data] = []
            while !Task.isCancelled {
                let chunk = fh.readData(ofLength: 2 * 1_048_576)
                guard !chunk.isEmpty else { break }
                chunks.append(chunk)
                await Task.yield()
            }
            try? fh.close()
            guard !Task.isCancelled, !chunks.isEmpty else { return }

            var raw = Data(capacity: chunks.reduce(0) { $0 + $1.count })
            chunks.forEach { raw.append($0) }
            let data = raw

            let hint = AudioPlaybackController.fileTypeHint(
                for: url.pathExtension.lowercased())

            await MainActor.run { [weak self] in
                guard let self, !Task.isCancelled else { return }
                let expected = deck == .A ? self.deckAFilePath : self.deckBFilePath
                guard expected == filePath else { return }  // deck was reassigned mid-load

                guard let p = try? AVAudioPlayer(data: data, fileTypeHint: hint) else { return }
                p.volume = Float(self.volume)
                p.prepareToPlay()

                let delegate = PlayerDelegate()
                delegate.owner = self
                p.delegate = delegate

                if deck == .A {
                    self.deckAPlayer   = p
                    self.deckADelegate = delegate
                    self.deckALoadTask = nil
                } else {
                    self.deckBPlayer   = p
                    self.deckBDelegate = delegate
                    self.deckBLoadTask = nil
                }
            }
        }
        if deck == .A { deckALoadTask = task } else { deckBLoadTask = task }
    }

    /// Remove a deck slot's player and cancel any in-flight load.
    func unloadDeck(_ deck: Deck) {
        if (deck == .A && activeSource == .deckA) ||
           (deck == .B && activeSource == .deckB) {
            stopTimer()
            isPlaying       = false
            currentFilePath = nil
            currentTime     = 0
            duration        = 0
            activeSource    = .single
        }
        cancelDeckLoad(deck)
        if deck == .A {
            deckAPlayer = nil; deckADelegate = nil; deckAFilePath = nil
        } else {
            deckBPlayer = nil; deckBDelegate = nil; deckBFilePath = nil
        }
    }

    /// Promote Deck B → Deck A in-place (called by addCandidateToSet after commit).
    /// Moves the in-RAM player and its playback position to the A slot without
    /// reloading from disk. If B was the active source, A becomes the active source.
    func promoteDeckBToA() {
        cancelDeckLoad(.A)
        deckAPlayer   = deckBPlayer
        deckAFilePath = deckBFilePath
        deckADelegate = deckBDelegate
        deckALoadTask = nil

        deckBPlayer   = nil
        deckBFilePath = nil
        deckBDelegate = nil
        deckBLoadTask?.cancel(); deckBLoadTask = nil

        if activeSource == .deckB { activeSource = .deckA }
        // currentFilePath is unchanged — same file, just moved from B slot to A slot.
    }

    // MARK: - Backward-compatible wrappers (existing callers unchanged)

    /// Preload the candidate (Next Up) file into Deck B.
    func preloadAudio(filePath: String) { loadDeck(.B, filePath: filePath) }

    /// Cancel the Deck B preload.
    func cancelPreload() { unloadDeck(.B) }

    // MARK: - Waveform

    func loadWaveformIfNeeded(filePath: String) {
        guard waveformCache[filePath] == nil,
              !loadingWaveformPaths.contains(filePath),
              !failedWaveformPaths.contains(filePath) else { return }
        loadingWaveformPaths.insert(filePath)

        let container = modelContainer
        Task { [weak self] in
            guard let self else { return }

            // 1. Persistent cache — background fetch, no main-thread I/O.
            if let container {
                let fp = filePath
                let cached = await Task.detached(priority: .utility) {
                    () -> (peaks: [Float], colors: Data)? in
                    let ctx = ModelContext(container)
                    var fd  = FetchDescriptor<LocalFileEntity>(
                        predicate: #Predicate { $0.filePath == fp }
                    )
                    fd.fetchLimit = 1
                    guard let entity = try? ctx.fetch(fd).first else { return nil }

                    // If peaks are cached but colors missing (row predates this feature),
                    // clear peaks so the generator runs and produces both fields together.
                    guard let peakData  = entity.waveformPeaks,  !peakData.isEmpty,
                          let colorData = entity.waveformColors, !colorData.isEmpty else {
                        if entity.waveformPeaks != nil {
                            entity.waveformPeaks = nil
                            try? ctx.save()
                        }
                        return nil
                    }

                    let count = peakData.count / MemoryLayout<Float>.size
                    let peaks = peakData.withUnsafeBytes { ptr in
                        Array(ptr.bindMemory(to: Float.self).prefix(count))
                    }
                    return (peaks, colorData)
                }.value

                if let cached {
                    self.loadingWaveformPaths.remove(filePath)
                    self.waveformCache[filePath]       = cached.peaks
                    self.waveformColorsCache[filePath] = cached.colors
                    return
                }
            }

            // 2. Generate on dedicated GCD queue (not cooperative pool — no UI stall).
            let result = await WaveformGenerator.generate(filePath: filePath)
            self.loadingWaveformPaths.remove(filePath)

            if let result {
                self.waveformCache[filePath]       = result.peaks
                self.waveformColorsCache[filePath] = result.colors
                // 3. Persist both fields so this file is never recomputed.
                if let container {
                    let fp        = filePath
                    let peakData  = result.peaks.withUnsafeBytes { Data($0) }
                    let colorData = result.colors
                    Task.detached(priority: .utility) {
                        let ctx = ModelContext(container)
                        var fd  = FetchDescriptor<LocalFileEntity>(
                            predicate: #Predicate { $0.filePath == fp }
                        )
                        fd.fetchLimit = 1
                        guard let entity = try? ctx.fetch(fd).first else { return }
                        entity.waveformPeaks  = peakData
                        entity.waveformColors = colorData
                        try? ctx.save()
                    }
                }
            } else {
                self.failedWaveformPaths.insert(filePath)
            }
        }
    }

    func waveformColors(filePath: String) -> Data? { waveformColorsCache[filePath] }

    func waveformState(for filePath: String) -> WaveformState {
        if let peaks = waveformCache[filePath] { return .ready(peaks) }
        if loadingWaveformPaths.contains(filePath)  { return .loading }
        if failedWaveformPaths.contains(filePath)   { return .failed }
        return .idle
    }

    // MARK: - Delegate callbacks

    func handlePlaybackFinished() {
        isPlaying   = false
        currentTime = duration
        stopTimer()
        playbackFinishedCount += 1
    }

    func handleDecodeError(_ message: String) {
        if let path = currentFilePath { playbackErrors[path] = message }
        isPlaying = false
        stopTimer()
    }

    // MARK: - Private helpers

    /// Pause whoever is currently active, leaving their position intact.
    private func pauseCurrentActive() {
        switch activeSource {
        case .single:
            player?.pause()
            ramLoadTask?.cancel(); ramLoadTask = nil
        case .deckA:
            deckAPlayer?.pause()
        case .deckB:
            deckBPlayer?.pause()
        }
        stopTimer()
    }

    private func stopSinglePlayer() {
        player?.stop()
        player         = nil
        playerDelegate = nil
        ramLoadTask?.cancel(); ramLoadTask = nil
    }

    private func cancelDeckLoad(_ deck: Deck) {
        if deck == .A { deckALoadTask?.cancel(); deckALoadTask = nil }
        else          { deckBLoadTask?.cancel(); deckBLoadTask = nil }
    }

    /// Stream Track A from NAS immediately, then atomically swap to an in-RAM player
    /// once the background read completes. Only used on the single-player path.
    private func startRAMLoad(filePath: String, url: URL) {
        ramLoadTask = Task.detached(priority: .utility) { [weak self] in
            let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            guard fileSize > 0,
                  fileSize <= AudioPlaybackController.maxRAMAudioBytes else { return }

            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }

            guard let fh = try? FileHandle(forReadingFrom: url) else { return }
            var chunks: [Data] = []
            while !Task.isCancelled {
                let chunk = fh.readData(ofLength: 2 * 1_048_576)
                guard !chunk.isEmpty else { break }
                chunks.append(chunk)
                await Task.yield()
            }
            try? fh.close()
            guard !Task.isCancelled, !chunks.isEmpty else { return }

            var raw = Data(capacity: chunks.reduce(0) { $0 + $1.count })
            chunks.forEach { raw.append($0) }
            let data = raw

            let hint = AudioPlaybackController.fileTypeHint(
                for: url.pathExtension.lowercased())

            await MainActor.run { [weak self] in
                guard let self,
                      self.currentFilePath == filePath,
                      self.activeSource    == .single else { return }
                guard let ramPlayer = try? AVAudioPlayer(data: data,
                                                        fileTypeHint: hint) else { return }

                let t          = self.player?.currentTime ?? self.currentTime
                let wasPlaying = self.isPlaying

                let delegate = PlayerDelegate()
                delegate.owner  = self
                ramPlayer.delegate    = delegate
                ramPlayer.volume      = Float(self.volume)
                ramPlayer.currentTime = t
                ramPlayer.prepareToPlay()

                self.player?.stop()
                self.player        = ramPlayer
                self.playerDelegate = delegate
                if wasPlaying { ramPlayer.play() }
                self.currentTime   = t
                self.ramLoadTask   = nil
            }
        }
    }

    nonisolated private static func fileTypeHint(for ext: String) -> String {
        switch ext {
        case "mp3":          return AVFileType.mp3.rawValue
        case "aiff", "aif":  return AVFileType.aiff.rawValue
        case "wav":          return AVFileType.wav.rawValue
        case "m4a":          return AVFileType.m4a.rawValue
        case "flac":         return "public.flac"
        case "caf":          return AVFileType.caf.rawValue
        default:             return ""
        }
    }

    private func startTimer() {
        timer?.invalidate()
        let t = Timer(timeInterval: 1.0 / 25.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.currentTime = self.activePlayer?.currentTime ?? self.currentTime
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}

// MARK: - Delegate (NSObject wrapper keeps AudioPlaybackController free of NSObject)

private final class PlayerDelegate: NSObject, AVAudioPlayerDelegate,
                                     @unchecked Sendable {
    weak var owner: AudioPlaybackController?

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in self?.owner?.handlePlaybackFinished() }
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        let msg = error?.localizedDescription ?? "Audio decode error"
        Task { @MainActor [weak self] in self?.owner?.handleDecodeError(msg) }
    }
}
