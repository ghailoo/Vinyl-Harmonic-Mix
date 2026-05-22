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

    // MARK: - Private

    private var player: AVAudioPlayer?
    private var playerDelegate: PlayerDelegate?
    private var timer: Timer?

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

        // New file — stop whatever is playing
        stopPlaybackInternal()
        currentFilePath = filePath
        playbackErrors.removeValue(forKey: filePath)

        let url = URL(fileURLWithPath: filePath)
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

    // MARK: - Internal callbacks (called by PlayerDelegate on MainActor)

    func handlePlaybackFinished() {
        isPlaying = false
        currentTime = duration
        stopTimer()
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
