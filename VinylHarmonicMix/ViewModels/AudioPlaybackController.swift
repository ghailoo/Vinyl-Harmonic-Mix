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
    private(set) var loadedFilePath: String? = nil
    private(set) var isPlaying: Bool = false
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    private(set) var playbackErrors: [String: String] = [:]
    private(set) var playbackFinishedCount: Int = 0

    // Set-playback state — empty playingSetItems means no set is active
    private(set) var playingSetItems: [SetlistItemEntity] = []
    private(set) var playingSetIndex: Int = 0

    // MARK: - Smart extension (whole-library auto-advance after set ends)

    /// Pool of confident-matched tracks with Camelot+BPM data. Set externally when library changes.
    var smartAdvancePool: [MixTrack] = []

    /// True when nextTrack() has fallen off the end of a saved set and is now extending via library.
    private(set) var isSmartExtensionActive: Bool = false

    /// Anti-repeat tracking within a single smart extension run.
    private var smartPlayedFilePaths: Set<String> = []

    // MARK: - Pre-load (Phase 2)

    /// Player initialized in advance for the predicted next track. Nil when no preload is ready.
    private var preloadedPlayer: AVAudioPlayer? = nil

    /// File path the preloaded player corresponds to. Used to verify the preload is still relevant.
    private var preloadedFilePath: String? = nil

    /// True while a preload task is in flight, prevents duplicate firing.
    private var isPreloadInFlight: Bool = false

    // Mix-mode deck state — both decks observable simultaneously
    private(set) var deckACurrentTime: Double = 0
    private(set) var deckBCurrentTime: Double = 0
    private(set) var deckADuration:    Double = 0
    private(set) var deckBDuration:    Double = 0
    private(set) var deckAIsPlaying:   Bool   = false
    private(set) var deckBIsPlaying:   Bool   = false

    var crossfade: Double = 0.5 { didSet { applyCrossfade() } }

    var volume: Double = 1.0 {
        didSet {
            player?.volume = Float(volume)
            applyCrossfade()
        }
    }

    // MARK: - Waveform state (unchanged)

    private(set) var waveformCache: [String: [Float]] = [:]
    private(set) var waveformColorsCache: [String: Data] = [:]
    private(set) var loadingWaveformPaths: Set<String> = []
    private(set) var failedWaveformPaths: Set<String> = []
    private var waveformTasks:  [String: Task<Void, Never>] = [:]
    private var waveformTokens: [String: CancellationToken] = [:]

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

        // ── Preload invalidation ─────────────────────────────────────────────
        // Any explicit user-initiated play for a different file makes the preload stale.
        if preloadedFilePath != filePath {
            preloadedPlayer?.stop()
            preloadedPlayer    = nil
            preloadedFilePath  = nil
        }

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
            loadedFilePath  = filePath
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
            loadedFilePath  = filePath
            duration        = deckB.duration
            currentTime     = deckB.currentTime
            deckB.volume    = Float(volume)
            deckB.play()
            isPlaying = true
            startTimer()
            playbackErrors.removeValue(forKey: filePath)
            return
        }

        // ── New file not in either deck — background-init to avoid main-thread block ─
        // AVAudioPlayer(contentsOf:) + prepareToPlay() can block 3-6s on NAS files.
        // Deck players keep their positions (paused, not stopped).
        pauseCurrentActive()
        activeSource = .single
        stopSinglePlayer()

        // Optimistic UI state: claim the path immediately so the toggle-check at top
        // works on the next call, and so race-protection in the Task can compare against it.
        let url          = URL(fileURLWithPath: filePath)
        let intendedPath = filePath
        currentFilePath  = filePath
        loadedFilePath   = filePath
        isPlaying        = false
        duration         = 0
        currentTime      = 0
        playbackErrors.removeValue(forKey: filePath)

        // Fast path: Track B was fully preloaded and this new file matches it.
        // (Handles the case where loadDeck(.B) completed but deckBFilePath check
        //  above missed because deckBPlayer was nil when loadDeck started.)
        // — deliberately not repeated here; covered by the deckB check above.

        Task.detached(priority: .userInitiated) { [weak self] in
            let result: Result<AVAudioPlayer, Error> = Result {
                let p = try AVAudioPlayer(contentsOf: url)
                p.prepareToPlay()
                return p
            }

            await MainActor.run {
                guard let self else { return }

                // Race-protection: if another track was requested while we were loading,
                // discard this stale result rather than clobbering the newer track.
                guard self.currentFilePath == intendedPath else {
                    print("[PLAY] Stale load for \(url.lastPathComponent), discarding")
                    return
                }

                switch result {
                case .success(let p):
                    let delegate   = PlayerDelegate()
                    delegate.owner = self
                    p.delegate     = delegate
                    p.volume       = Float(self.volume)
                    p.play()
                    self.player         = p
                    self.playerDelegate = delegate
                    self.duration       = p.duration
                    self.currentTime    = 0
                    self.isPlaying      = true
                    self.startTimer()
                    self.loadWaveformIfNeeded(filePath: intendedPath)
                    self.startRAMLoad(filePath: intendedPath, url: url)

                case .failure(let error):
                    self.playbackErrors[intendedPath] = error.localizedDescription
                    self.player         = nil
                    self.playerDelegate = nil
                    self.isPlaying      = false
                    self.duration       = 0
                    self.currentTime    = 0
                }
            }
        }
    }

    func pause() {
        activePlayer?.pause()
        stopTimer()
        isPlaying = false
    }

    func setLoadedFile(_ path: String?) {
        loadedFilePath = path
    }

    func stop() {
        stopSinglePlayer()
        // Pause deck players so they hold their positions.
        deckAPlayer?.pause()
        deckBPlayer?.pause()
        stopTimer()
        isPlaying       = false
        currentFilePath = nil
        loadedFilePath  = nil
        currentTime     = 0
        duration        = 0
        activeSource    = .single
        // Stop = "I'm done" — exit set-playback, smart-extension, and preload modes
        playingSetItems = []
        playingSetIndex = 0
        isSmartExtensionActive = false
        smartPlayedFilePaths.removeAll()
        preloadedPlayer?.stop()
        preloadedPlayer   = nil
        preloadedFilePath = nil
        isPreloadInFlight = false
    }

    func seek(toFraction fraction: Double) {
        guard let p = activePlayer, duration > 0 else { return }
        let clamped = max(0, min(1, fraction))
        p.currentTime = clamped * p.duration
        currentTime   = p.currentTime
    }

    func seek(to time: Double) {
        guard let p = activePlayer, duration > 0 else { return }
        p.currentTime = max(0, min(time, duration))
        currentTime   = p.currentTime
    }

    func skip(seconds: Double) { seek(to: currentTime + seconds) }
    func skipBackward10()      { skip(seconds: -10) }
    func skipForward10()       { skip(seconds:  10) }

    // MARK: - Set playback

    func startSet(_ items: [SetlistItemEntity]) {
        stop()
        guard let firstIdx = items.firstIndex(where: { !$0.filePath.isEmpty }) else { return }
        playingSetItems = items
        playingSetIndex = firstIdx
        play(filePath: items[firstIdx].filePath)
    }

    func stopSet() {
        // NOTE: do NOT reset smart-extension state here — stopSet() is called internally
        // during the handoff from set mode into extension mode.
        playingSetItems = []
        playingSetIndex = 0
    }

    func nextTrack() {
        // Smart-extension skip: advance to the next harmonic match from the current track.
        if isSmartExtensionActive {
            guard let currentPath = currentFilePath else {
                isSmartExtensionActive = false
                smartPlayedFilePaths.removeAll()
                stop()
                return
            }
            if let next = pickNextHarmonicTrack(after: currentPath),
               let nextPath = next.filePath {
                smartPlayedFilePaths.insert(nextPath)
                playUsingPreloadIfAvailable(filePath: nextPath)
            } else {
                isSmartExtensionActive = false
                smartPlayedFilePaths.removeAll()
                stop()
            }
            return
        }

        guard !playingSetItems.isEmpty else { return }
        var next = playingSetIndex + 1
        while next < playingSetItems.count && playingSetItems[next].filePath.isEmpty {
            next += 1
        }
        if next >= playingSetItems.count {
            // End of set — try to extend via smart pool.
            let lastAnchorPath = playingSetItems[playingSetIndex].filePath
            if !lastAnchorPath.isEmpty,
               let extensionTrack = pickNextHarmonicTrack(after: lastAnchorPath),
               let extensionPath = extensionTrack.filePath {
                isSmartExtensionActive = true
                smartPlayedFilePaths.insert(lastAnchorPath)
                smartPlayedFilePaths.insert(extensionPath)
                stopSet()
                playUsingPreloadIfAvailable(filePath: extensionPath)
                return
            }
            stopSet()
            stop()
            return
        }
        playingSetIndex = next
        playUsingPreloadIfAvailable(filePath: playingSetItems[next].filePath)
    }

    private func predictedNextFilePath() -> String? {
        if !playingSetItems.isEmpty {
            var next = playingSetIndex + 1
            while next < playingSetItems.count && playingSetItems[next].filePath.isEmpty {
                next += 1
            }
            if next < playingSetItems.count {
                return playingSetItems[next].filePath
            }
            // Last track of set — predict the smart extension target.
            guard let currentPath = currentFilePath else { return nil }
            return pickNextHarmonicTrack(after: currentPath)?.filePath
        }

        if isSmartExtensionActive, let currentPath = currentFilePath {
            return pickNextHarmonicTrack(after: currentPath)?.filePath
        }

        return nil
    }

    private func maybeTriggerPreload() {
        guard duration > 0 else { return }
        guard !isPreloadInFlight else { return }
        guard preloadedPlayer == nil else { return }
        guard duration - currentTime <= 30 else { return }

        guard let nextPath = predictedNextFilePath() else { return }
        guard nextPath != currentFilePath else { return }

        isPreloadInFlight = true
        let url           = URL(fileURLWithPath: nextPath)
        let intendedPath  = nextPath

        Task.detached(priority: .utility) { [weak self] in
            let result: Result<AVAudioPlayer, Error> = Result {
                let p = try AVAudioPlayer(contentsOf: url)
                p.prepareToPlay()
                return p
            }

            await MainActor.run {
                guard let self else { return }
                self.isPreloadInFlight = false

                guard self.predictedNextFilePath() == intendedPath else {
                    print("[PRELOAD] Stale — predicted next changed, discarding \(url.lastPathComponent)")
                    return
                }

                switch result {
                case .success(let p):
                    self.preloadedPlayer   = p
                    self.preloadedFilePath = intendedPath
                    print("[PRELOAD] Ready: \(url.lastPathComponent)")
                case .failure(let error):
                    print("[PRELOAD] Failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private func playUsingPreloadIfAvailable(filePath: String) {
        if let p = preloadedPlayer, preloadedFilePath == filePath {
            let claimed   = p
            preloadedPlayer   = nil
            preloadedFilePath = nil

            pauseCurrentActive()
            activeSource = .single
            stopSinglePlayer()

            let delegate   = PlayerDelegate()
            delegate.owner = self
            claimed.delegate = delegate
            claimed.volume   = Float(volume)
            claimed.play()

            player          = claimed
            playerDelegate  = delegate
            duration        = claimed.duration
            currentTime     = 0
            isPlaying       = true
            currentFilePath = filePath
            loadedFilePath  = filePath
            playbackErrors.removeValue(forKey: filePath)
            startTimer()

            loadWaveformIfNeeded(filePath: filePath)
            startRAMLoad(filePath: filePath, url: URL(fileURLWithPath: filePath))

            print("[PRELOAD] Used preloaded player for \(URL(fileURLWithPath: filePath).lastPathComponent)")
            return
        }

        play(filePath: filePath)
    }

    private func pickNextHarmonicTrack(after anchorPath: String) -> MixTrack? {
        guard let anchor = smartAdvancePool.first(where: { $0.filePath == anchorPath }),
              !smartAdvancePool.isEmpty else { return nil }

        let excluded = smartPlayedFilePaths.union([anchorPath])
        let candidates = smartAdvancePool.filter {
            guard let path = $0.filePath else { return false }
            return !excluded.contains(path)
        }
        guard !candidates.isEmpty else { return nil }

        // 3-pass BPM constraint relaxation — always harmonic, no camelot fallback.
        let tolerances: [Double] = [0.06, 0.10, 0.15]
        for pct in tolerances {
            let absTolerance = anchor.bpm * pct
            let groups = HarmonicCompatibility.compatibleGroups(
                for: anchor, in: candidates, bpmTolerance: absTolerance
            )
            // Priority order: perfectMatch → moodSwitch → energyBoost → energyDrop
            for group in [HarmonicGroup.perfectMatch, .moodSwitch, .energyBoost, .energyDrop] {
                if let match = groups[group]?.first {
                    return match.track
                }
            }
        }
        return nil
    }

    func previousTrack() {
        guard !playingSetItems.isEmpty else { return }
        var prev = playingSetIndex - 1
        while prev >= 0 && playingSetItems[prev].filePath.isEmpty {
            prev -= 1
        }
        guard prev >= 0 else { return }
        playingSetIndex = prev
        play(filePath: playingSetItems[prev].filePath)
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
                    self.deckADuration = p.duration
                } else {
                    self.deckBPlayer   = p
                    self.deckBDelegate = delegate
                    self.deckBLoadTask = nil
                    self.deckBDuration = p.duration
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
            deckACurrentTime = 0; deckADuration = 0; deckAIsPlaying = false
        } else {
            deckBPlayer = nil; deckBDelegate = nil; deckBFilePath = nil
            deckBCurrentTime = 0; deckBDuration = 0; deckBIsPlaying = false
        }
    }

    /// Promote Deck B → Deck A in-place (called by addCandidateToSet after commit).
    /// Moves the in-RAM player and its playback position to the A slot without
    /// reloading from disk. If B was the active source, A becomes the active source.
    func promoteDeckBToA() {
        cancelDeckLoad(.A)
        deckAPlayer      = deckBPlayer
        deckAFilePath    = deckBFilePath
        deckADelegate    = deckBDelegate
        deckALoadTask    = nil
        deckADuration    = deckBDuration
        deckACurrentTime = deckBCurrentTime
        deckAIsPlaying   = deckBIsPlaying

        deckBPlayer      = nil
        deckBFilePath    = nil
        deckBDelegate    = nil
        deckBLoadTask?.cancel(); deckBLoadTask = nil
        deckBDuration    = 0
        deckBCurrentTime = 0
        deckBIsPlaying   = false

        if activeSource == .deckB { activeSource = .deckA }
        crossfade = 0   // B slot is empty — snap fader to full deck A
    }

    // MARK: - Backward-compatible wrappers (existing callers unchanged)

    /// Preload the candidate (Next Up) file into Deck B.
    func preloadAudio(filePath: String) { loadDeck(.B, filePath: filePath) }

    /// Cancel the Deck B preload.
    func cancelPreload() { unloadDeck(.B) }

    // MARK: - Mix-mode per-deck playback controls
    // These are the Mix-mode entry points. Unlike play(filePath:), they do NOT call
    // pauseCurrentActive() — both decks can run simultaneously while the fader blends them.

    func playDeckA() {
        guard let p = deckAPlayer else { return }
        if p.isPlaying {
            p.pause()
            deckAIsPlaying = false
            if !anyPlayerActive { stopTimer() }
        } else {
            applyCrossfade()
            p.play()
            deckAIsPlaying = true
            if let fp = deckAFilePath { playbackErrors.removeValue(forKey: fp) }
            startTimer()
        }
    }

    func pauseDeckA() {
        guard deckAPlayer?.isPlaying == true else { return }
        deckAPlayer?.pause()
        deckAIsPlaying = false
        if !anyPlayerActive { stopTimer() }
    }

    func seekDeckA(toFraction fraction: Double) {
        guard let p = deckAPlayer else { return }
        let t = max(0, min(1, fraction)) * p.duration
        p.currentTime = t
        deckACurrentTime = t
    }

    func playDeckB() {
        guard let p = deckBPlayer else { return }
        if p.isPlaying {
            p.pause()
            deckBIsPlaying = false
            if !anyPlayerActive { stopTimer() }
        } else {
            applyCrossfade()
            p.play()
            deckBIsPlaying = true
            if let fp = deckBFilePath { playbackErrors.removeValue(forKey: fp) }
            startTimer()
        }
    }

    func pauseDeckB() {
        guard deckBPlayer?.isPlaying == true else { return }
        deckBPlayer?.pause()
        deckBIsPlaying = false
        if !anyPlayerActive { stopTimer() }
    }

    func seekDeckB(toFraction fraction: Double) {
        guard let p = deckBPlayer else { return }
        let t = max(0, min(1, fraction)) * p.duration
        p.currentTime = t
        deckBCurrentTime = t
    }

    // MARK: - Waveform

    func loadWaveformIfNeeded(filePath: String) {
        guard waveformCache[filePath] == nil,
              !loadingWaveformPaths.contains(filePath),
              !failedWaveformPaths.contains(filePath) else { return }
        loadingWaveformPaths.insert(filePath)

        let container = modelContainer
        let token = CancellationToken()
        waveformTokens[filePath] = token
        let task = Task { [weak self] in
            guard let self else { return }
            let taskStart = Date()
            let baseName  = URL(fileURLWithPath: filePath).lastPathComponent
            print("[WF-LOAD] \(baseName) — task start")
            defer {
                if self.waveformTokens[filePath] === token {
                    self.waveformTasks[filePath]  = nil
                    self.waveformTokens[filePath] = nil
                }
            }

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
                    if self.waveformTokens[filePath] === token {
                        self.loadingWaveformPaths.remove(filePath)
                    }
                    self.waveformCache[filePath]       = cached.peaks
                    self.waveformColorsCache[filePath] = cached.colors
                    print("[WF-LOAD] \(baseName) — DB cache hit, done in \(String(format: "%.3f", Date().timeIntervalSince(taskStart)))s")
                    return
                }
            }

            // 2. Generate on dedicated GCD queue (not cooperative pool — no UI stall).
            let result = await WaveformGenerator.generate(filePath: filePath, token: token)
            if self.waveformTokens[filePath] === token {
                self.loadingWaveformPaths.remove(filePath)
            }

            if let result {
                self.waveformCache[filePath]       = result.peaks
                self.waveformColorsCache[filePath] = result.colors
                print("[WF-LOAD] \(baseName) — generated in \(String(format: "%.3f", Date().timeIntervalSince(taskStart)))s")
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
            } else if token.isCancelled {
                print("[WF-LOAD] \(baseName) — cancelled")
            } else {
                self.failedWaveformPaths.insert(filePath)
                print("[WF-LOAD] \(baseName) — generate failed, total \(String(format: "%.3f", Date().timeIntervalSince(taskStart)))s")
            }
        }
        waveformTasks[filePath] = task
    }

    func cancelWaveformLoads(filePaths: [String]) {
        for fp in filePaths {
            guard waveformCache[fp] == nil else { continue }
            waveformTokens[fp]?.isCancelled = true
            waveformTasks[fp]?.cancel()
            loadingWaveformPaths.remove(fp)
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

    func handlePlaybackFinished(player finishedPlayer: AVAudioPlayer? = nil) {
        // Track which player finished so smart extension only fires for single-player completions.
        let isSinglePlayer = finishedPlayer == nil ||
            (finishedPlayer !== deckAPlayer && finishedPlayer !== deckBPlayer)

        if finishedPlayer != nil && finishedPlayer === deckAPlayer {
            deckAIsPlaying   = false
            deckACurrentTime = deckADuration
        } else if finishedPlayer != nil && finishedPlayer === deckBPlayer {
            deckBIsPlaying   = false
            deckBCurrentTime = deckBDuration
        } else {
            isPlaying   = false
            currentTime = duration
        }
        if !anyPlayerActive { stopTimer() }
        playbackFinishedCount += 1

        if !playingSetItems.isEmpty {
            nextTrack()
        } else if isSinglePlayer && isSmartExtensionActive, let currentPath = currentFilePath {
            if let next = pickNextHarmonicTrack(after: currentPath),
               let nextPath = next.filePath {
                smartPlayedFilePaths.insert(nextPath)
                playUsingPreloadIfAvailable(filePath: nextPath)
            } else {
                isSmartExtensionActive = false
                smartPlayedFilePaths.removeAll()
                stop()
            }
        }
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

    private func applyCrossfade() {
        let v     = Float(volume)
        let aGain = Float(cos(crossfade * .pi / 2))
        let bGain = Float(sin(crossfade * .pi / 2))
        deckAPlayer?.volume = v * aGain
        deckBPlayer?.volume = v * bGain
    }

    private var anyPlayerActive: Bool {
        player?.isPlaying == true
        || deckAPlayer?.isPlaying == true
        || deckBPlayer?.isPlaying == true
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
                self.maybeTriggerPreload()
                if let a = self.deckAPlayer {
                    self.deckACurrentTime = a.currentTime
                    self.deckAIsPlaying   = a.isPlaying
                }
                if let b = self.deckBPlayer {
                    self.deckBCurrentTime = b.currentTime
                    self.deckBIsPlaying   = b.isPlaying
                }
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
        let p = player
        Task { @MainActor [weak self] in self?.owner?.handlePlaybackFinished(player: p) }
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        let msg = error?.localizedDescription ?? "Audio decode error"
        Task { @MainActor [weak self] in self?.owner?.handleDecodeError(msg) }
    }
}
