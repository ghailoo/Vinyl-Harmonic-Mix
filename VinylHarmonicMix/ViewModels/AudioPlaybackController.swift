import AVFoundation
import Foundation

@MainActor
@Observable
final class AudioPlaybackController {

    // MARK: - Playback state

    private(set) var currentFilePath: String? = nil
    private(set) var isPlaying: Bool = false
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    // Per-file error strings; keyed by filePath so each row shows its own error.
    private(set) var playbackErrors: [String: String] = [:]

    // MARK: - Volume (0…1, persists across track changes)

    var volume: Double = 1.0 {
        didSet { player?.volume = Float(volume) }
    }

    // MARK: - Waveform state

    private(set) var waveformCache: [String: [Float]] = [:]
    private(set) var loadingWaveformPaths: Set<String> = []
    private(set) var failedWaveformPaths: Set<String> = []

    enum WaveformState {
        case idle, loading, failed
        case ready([Float])
    }

    // MARK: - Private — active player

    private var player: AVAudioPlayer?
    private var playerDelegate: PlayerDelegate?
    private var timer: Timer?
    private var ramLoadTask: Task<Void, Never>?  // stream-then-swap for Track A

    // MARK: - Private — Track B preload

    private var preloadedPlayer: AVAudioPlayer?
    private var preloadedFilePath: String?
    private var preloadTask: Task<Void, Never>?

    // Files larger than this stay on the NAS-streamed player (rare >200 MB tracks).
    // nonisolated: read from Task.detached without hopping to @MainActor.
    nonisolated private static let maxRAMAudioBytes = 200 * 1_048_576

    // MARK: - Controls

    /// Play the file at `filePath`, or toggle pause/resume if it's already loaded.
    func play(filePath: String) {
        if currentFilePath == filePath {
            if isPlaying {
                player?.pause()
                stopTimer()
                isPlaying = false
            } else {
                player?.play()
                startTimer()
                isPlaying = true
                playbackErrors.removeValue(forKey: filePath)
            }
            return
        }

        // New file — stop current player and cancel any in-flight RAM load for Track A.
        stopPlaybackInternal()
        currentFilePath = filePath
        playbackErrors.removeValue(forKey: filePath)

        let url = URL(fileURLWithPath: filePath)

        // Fast path: Track B was fully preloaded into RAM — use it directly, no NAS hit.
        if filePath == preloadedFilePath {
            if let preloaded = preloadedPlayer {
                preloadedPlayer = nil
                preloadedFilePath = nil
                preloadTask?.cancel(); preloadTask = nil

                let delegate = PlayerDelegate()
                delegate.owner = self
                preloaded.delegate = delegate
                preloaded.volume = Float(volume)
                preloaded.currentTime = 0
                preloaded.prepareToPlay()
                preloaded.play()
                player = preloaded
                playerDelegate = delegate
                duration = preloaded.duration
                currentTime = 0
                isPlaying = true
                startTimer()
                loadWaveformIfNeeded(filePath: filePath)
                return
            } else {
                // Preload is still in-flight; cancel it and fall through to stream.
                preloadTask?.cancel(); preloadTask = nil
                preloadedFilePath = nil
            }
        }

        // Normal path: stream from NAS immediately (zero startup gap), then swap to RAM.
        do {
            let p = try AVAudioPlayer(contentsOf: url)
            let delegate = PlayerDelegate()
            delegate.owner = self
            p.delegate = delegate
            p.volume = Float(volume)
            p.prepareToPlay()
            p.play()
            player = p
            playerDelegate = delegate
            duration = p.duration
            currentTime = 0
            isPlaying = true
            startTimer()
        } catch {
            playbackErrors[filePath] = error.localizedDescription
            player = nil
            playerDelegate = nil
            isPlaying = false
            duration = 0
            currentTime = 0
        }

        loadWaveformIfNeeded(filePath: filePath)
        startRAMLoad(filePath: filePath, url: url)
    }

    func pause() {
        player?.pause()
        stopTimer()
        isPlaying = false
    }

    func stop() {
        stopPlaybackInternal()
        currentFilePath = nil
    }

    /// Seek to a fraction (0…1) of the current track's duration.
    func seek(toFraction fraction: Double) {
        guard let player else { return }
        let clamped = max(0, min(1, fraction))
        player.currentTime = clamped * player.duration
        currentTime = player.currentTime
    }

    // MARK: - Waveform

    func loadWaveformIfNeeded(filePath: String) {
        guard waveformCache[filePath] == nil,
              !loadingWaveformPaths.contains(filePath),
              !failedWaveformPaths.contains(filePath) else { return }

        loadingWaveformPaths.insert(filePath)
        Task {
            let peaks = await WaveformGenerator.generate(filePath: filePath)
            loadingWaveformPaths.remove(filePath)
            if let peaks {
                waveformCache[filePath] = peaks
            } else {
                failedWaveformPaths.insert(filePath)
            }
        }
    }

    func waveformState(for filePath: String) -> WaveformState {
        if let peaks = waveformCache[filePath] { return .ready(peaks) }
        if loadingWaveformPaths.contains(filePath) { return .loading }
        if failedWaveformPaths.contains(filePath) { return .failed }
        return .idle
    }

    // MARK: - Track B preload

    /// Preload `filePath` into RAM so the transition to it is instant.
    /// Low-priority, delayed 3 s, and chunked to avoid starving Track A's NAS reads.
    func preloadAudio(filePath: String) {
        guard !filePath.isEmpty else { return }
        if preloadedFilePath == filePath { return }   // already preloading / ready
        cancelPreload()
        preloadedFilePath = filePath                  // intent marker for dedup

        let url = URL(fileURLWithPath: filePath)

        preloadTask = Task.detached(priority: .background) { [weak self] in
            // Size cap — keeps the stat() off the main thread
            let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            guard fileSize > 0, fileSize <= AudioPlaybackController.maxRAMAudioBytes else {
                await MainActor.run { [weak self] in
                    guard let self, self.preloadedFilePath == filePath else { return }
                    self.preloadedFilePath = nil   // too big; B will cold-start if chosen
                }
                return
            }

            // Delay 3 s so Track A's startup NAS reads are done before we hit the network.
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }

            // Chunked read: 2 MB per chunk + yield so A's sequential reads get serviced.
            guard let fh = try? FileHandle(forReadingFrom: url) else {
                await MainActor.run { [weak self] in
                    guard let self, self.preloadedFilePath == filePath else { return }
                    self.preloadedFilePath = nil
                }
                return
            }
            var chunks: [Data] = []
            while !Task.isCancelled {
                let chunk = fh.readData(ofLength: 2 * 1_048_576)
                guard !chunk.isEmpty else { break }
                chunks.append(chunk)
                await Task.yield()
            }
            try? fh.close()
            guard !Task.isCancelled, !chunks.isEmpty else { return }

            var _data = Data(capacity: chunks.reduce(0) { $0 + $1.count })
            chunks.forEach { _data.append($0) }
            let data = _data   // let binding so the closure capture is Sendable-clean

            // Hint: lets CoreAudio skip magic-byte detection; critical for FLAC.
            let hint = AudioPlaybackController.fileTypeHint(for: url.pathExtension.lowercased())

            // Create player and call prepareToPlay on @MainActor (AVAudioPlayer requirement).
            await MainActor.run { [weak self] in
                guard let self, !Task.isCancelled,
                      self.preloadedFilePath == filePath else { return }
                guard let preloaded = try? AVAudioPlayer(data: data, fileTypeHint: hint) else {
                    self.preloadedFilePath = nil
                    return
                }
                preloaded.prepareToPlay()
                self.preloadedPlayer = preloaded
            }
        }
    }

    /// Cancel any in-flight Track B preload and release the preloaded player.
    func cancelPreload() {
        preloadTask?.cancel(); preloadTask = nil
        preloadedPlayer = nil
        preloadedFilePath = nil
    }

    // MARK: - Internal callbacks (called by PlayerDelegate on MainActor)

    /// Incremented each time a track ends naturally (AVAudioPlayerDelegate).
    /// Observers can watch this to auto-advance a play-queue; it is NOT incremented
    /// when the user pauses or stops, so pause-vs-finish is unambiguous.
    private(set) var playbackFinishedCount: Int = 0

    func handlePlaybackFinished() {
        isPlaying = false
        currentTime = duration
        stopTimer()
        playbackFinishedCount += 1
    }

    func handleDecodeError(_ message: String) {
        if let path = currentFilePath {
            playbackErrors[path] = message
        }
        isPlaying = false
        stopTimer()
    }

    // MARK: - Private helpers

    private func stopPlaybackInternal() {
        player?.stop()
        player = nil
        playerDelegate = nil
        stopTimer()
        isPlaying = false
        currentTime = 0
        duration = 0
        ramLoadTask?.cancel(); ramLoadTask = nil
    }

    /// Read Track A into RAM in the background. While loading, Track A plays from the
    /// NAS-streamed player. On completion, atomically swap to the in-RAM player so all
    /// subsequent seeks are instant. Data (Sendable) crosses the task boundary;
    /// AVAudioPlayer is created on @MainActor to stay off background threads.
    private func startRAMLoad(filePath: String, url: URL) {
        ramLoadTask = Task.detached(priority: .utility) { [weak self] in
            let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            guard fileSize > 0, fileSize <= AudioPlaybackController.maxRAMAudioBytes else { return }

            // Defer the full-file read past the waveform-generator's own NAS pass.
            // Both read the same file; overlapping them causes the 1-2s startup hitch.
            // Seeks aren't needed in the first few seconds, so the delay has no UX cost.
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

            var _data = Data(capacity: chunks.reduce(0) { $0 + $1.count })
            chunks.forEach { _data.append($0) }
            let data = _data   // let binding so the closure capture is Sendable-clean

            let hint = AudioPlaybackController.fileTypeHint(for: url.pathExtension.lowercased())

            await MainActor.run { [weak self] in
                guard let self, self.currentFilePath == filePath else { return }
                guard let ramPlayer = try? AVAudioPlayer(data: data, fileTypeHint: hint) else { return }

                // Capture state AT swap time — the track has been playing during the load.
                let t          = self.player?.currentTime ?? self.currentTime
                let wasPlaying = self.isPlaying

                let delegate = PlayerDelegate()
                delegate.owner = self
                ramPlayer.delegate = delegate
                ramPlayer.volume = Float(self.volume)
                ramPlayer.currentTime = t
                ramPlayer.prepareToPlay()   // pre-fills hardware buffer while old player is still running

                // Stop-then-play: eliminates double-audio; prepareToPlay above makes the
                // gap between stop and play inaudible (<1 ms).
                self.player?.stop()
                self.player = ramPlayer
                self.playerDelegate = delegate
                if wasPlaying { ramPlayer.play() }
                self.currentTime = t
                self.ramLoadTask = nil
            }
        }
    }

    // nonisolated: called from Task.detached contexts without hopping to @MainActor.
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
                guard let self, let p = self.player else { return }
                self.currentTime = p.currentTime
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

private final class PlayerDelegate: NSObject, AVAudioPlayerDelegate, @unchecked Sendable {
    weak var owner: AudioPlaybackController?

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            self?.owner?.handlePlaybackFinished()
        }
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        let msg = error?.localizedDescription ?? "Audio decode error"
        Task { @MainActor [weak self] in
            self?.owner?.handleDecodeError(msg)
        }
    }
}
