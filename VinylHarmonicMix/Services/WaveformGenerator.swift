import AVFoundation
import Accelerate

enum WaveformGenerator {

    // Dedicated serial GCD queue — completely isolated from the Swift cooperative
    // pool, so a full-file NAS read never blocks a MainActor hop or UI update.
    private static let waveformQueue = DispatchQueue(
        label: "com.vinylharmonic.waveform", qos: .utility)

    struct Result {
        let peaks: [Float]   // 4000 normalized amplitude peaks (0…1)
        let colors: Data     // 4000 × 3 × Float32 — [bass,mid,high] per bucket,
                             // each band independently normalized 0…1
    }

    static func generate(filePath: String, targetBuckets: Int = 4000) async -> Result? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Result?, Never>) in
            waveformQueue.async {
                guard FileManager.default.fileExists(atPath: filePath) else {
                    continuation.resume(returning: nil); return
                }
                let url = URL(fileURLWithPath: filePath)
                guard let file = try? AVAudioFile(forReading: url) else {
                    continuation.resume(returning: nil); return
                }

                let totalFrames = Int(file.length)
                guard totalFrames > 0 else {
                    continuation.resume(returning: nil); return
                }

                let framesPerBucket = max(1, totalFrames / targetBuckets)
                let format       = file.processingFormat
                let channelCount = Int(format.channelCount)
                let sampleRate   = Float(format.sampleRate)

                // ── FFT setup ─────────────────────────────────────────────────
                // Fixed 1024-point FFT — coarse band energy only, no need to
                // resolve individual bins. Snapshot from bucket centre avoids
                // the dynamic round-up (4096+) that scaled with track length.
                let fftSize = 1024
                let halfFFT = 512
                let log2n   = vDSP_Length(10)
                guard let fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
                    continuation.resume(returning: nil); return
                }
                defer { vDSP_destroy_fftsetup(fftSetup) }

                // Pre-compute Hz→bin boundaries.
                // Bin k ↔ k × sampleRate / fftSize Hz.
                let hzPerBin = sampleRate / Float(fftSize)
                let bassLo = max(0,       Int(  20.0 / hzPerBin))
                let bassHi = min(halfFFT, Int( 250.0 / hzPerBin))
                let midLo  = bassHi
                let midHi  = min(halfFFT, Int(4000.0 / hzPerBin))
                let highLo = midHi
                let highHi = min(halfFFT, Int(20000.0 / hzPerBin))

                // Hann window — computed once, applied to every bucket.
                var hannWindow = [Float](repeating: 0, count: fftSize)
                vDSP_hann_window(&hannWindow, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))

                // Reusable per-bucket buffers.
                var mono       = [Float](repeating: 0, count: fftSize)
                var realBuf    = [Float](repeating: 0, count: halfFFT)
                var imagBuf    = [Float](repeating: 0, count: halfFFT)
                var magnitudes = [Float](repeating: 0, count: halfFFT)

                guard let buffer = AVAudioPCMBuffer(
                    pcmFormat: format,
                    frameCapacity: AVAudioFrameCount(framesPerBucket)
                ) else {
                    continuation.resume(returning: nil); return
                }

                var peaks:   [Float] = []; peaks.reserveCapacity(targetBuckets + 4)
                var rawBass: [Float] = []; rawBass.reserveCapacity(targetBuckets + 4)
                var rawMid:  [Float] = []; rawMid.reserveCapacity(targetBuckets + 4)
                var rawHigh: [Float] = []; rawHigh.reserveCapacity(targetBuckets + 4)

                // ── Main decode / analysis loop ───────────────────────────────

                while true {
                    let framePosition = Int(file.framePosition)
                    let remaining     = totalFrames - framePosition
                    guard remaining > 0 else { break }

                    let toRead = min(AVAudioFrameCount(framesPerBucket),
                                    AVAudioFrameCount(remaining))
                    buffer.frameLength = 0
                    do { try file.read(into: buffer, frameCount: toRead) } catch { break }
                    guard buffer.frameLength > 0 else { break }
                    let frameCount = Int(buffer.frameLength)

                    // Amplitude peak (existing logic, unchanged).
                    var peak: Float = 0
                    for ch in 0..<channelCount {
                        guard let data = buffer.floatChannelData?[ch] else { continue }
                        for i in 0..<frameCount {
                            let v = abs(data[i])
                            if v > peak { peak = v }
                        }
                    }
                    peaks.append(peak)

                    // Mix a centre snapshot (≤1024 frames) to mono for FFT.
                    // Taking from the bucket centre avoids transient bias at edges.
                    let snapshotLen = min(frameCount, fftSize)
                    let snapshotStart = frameCount >= fftSize
                        ? frameCount / 2 - fftSize / 2
                        : 0
                    vDSP_vclr(&mono, 1, vDSP_Length(fftSize))
                    for ch in 0..<channelCount {
                        guard let src = buffer.floatChannelData?[ch] else { continue }
                        for i in 0..<snapshotLen { mono[i] += src[snapshotStart + i] }
                    }
                    if channelCount > 1 {
                        var scale = 1.0 / Float(channelCount)
                        mono.withUnsafeMutableBufferPointer { buf in
                            vDSP_vsmul(buf.baseAddress!, 1, &scale,
                                       buf.baseAddress!, 1, vDSP_Length(snapshotLen))
                        }
                    }

                    // Apply Hann window (full fftSize — zero-pad region is already 0).
                    hannWindow.withUnsafeBufferPointer { hwBuf in
                        mono.withUnsafeMutableBufferPointer { monoBuf in
                            vDSP_vmul(monoBuf.baseAddress!, 1, hwBuf.baseAddress!, 1,
                                      monoBuf.baseAddress!, 1, vDSP_Length(fftSize))
                        }
                    }

                    // Pack real data into split-complex form required by vDSP_fft_zrip:
                    // even-indexed samples → realp, odd-indexed → imagp.
                    realBuf.withUnsafeMutableBufferPointer { rp in
                        imagBuf.withUnsafeMutableBufferPointer { ip in
                            var split = DSPSplitComplex(realp: rp.baseAddress!,
                                                        imagp: ip.baseAddress!)
                            mono.withUnsafeBytes { raw in
                                vDSP_ctoz(raw.bindMemory(to: DSPComplex.self).baseAddress!,
                                          2, &split, 1, vDSP_Length(halfFFT))
                            }
                            vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                            // Squared magnitudes — sufficient for relative band energy;
                            // avoids sqrt and normalisation handles absolute scale.
                            magnitudes.withUnsafeMutableBufferPointer { mp in
                                vDSP_zvmags(&split, 1, mp.baseAddress!, 1, vDSP_Length(halfFFT))
                            }
                        }
                    }

                    // Sum squared magnitudes into three frequency bands.
                    magnitudes.withUnsafeBufferPointer { mp in
                        let p = mp.baseAddress!
                        var bE: Float = 0, mE: Float = 0, hE: Float = 0
                        let bLen = vDSP_Length(max(0, bassHi - bassLo))
                        let mLen = vDSP_Length(max(0, midHi  - midLo))
                        let hLen = vDSP_Length(max(0, highHi - highLo))
                        if bLen > 0 { vDSP_sve(p + bassLo, 1, &bE, bLen) }
                        if mLen > 0 { vDSP_sve(p + midLo,  1, &mE, mLen) }
                        if hLen > 0 { vDSP_sve(p + highLo, 1, &hE, hLen) }
                        rawBass.append(bE)
                        rawMid.append(mE)
                        rawHigh.append(hE)
                    }

                    if buffer.frameLength < toRead { break }
                    if peaks.count >= targetBuckets + 4 { break }
                }

                guard !peaks.isEmpty else {
                    continuation.resume(returning: nil); return
                }

                // ── Normalize amplitude peaks ─────────────────────────────────
                let maxPeak   = peaks.max() ?? 0
                let normPeaks = maxPeak > 0 ? peaks.map { $0 / maxPeak } : peaks

                // ── Per-band normalization ─────────────────────────────────────
                // Each band is divided by its OWN maximum so that bass, mid, and
                // high each span 0…1 independently. Without this, raw bass energy
                // dominates and high-frequency content is invisible.
                let bassMax = rawBass.max() ?? 0
                let midMax  = rawMid.max()  ?? 0
                let highMax = rawHigh.max() ?? 0

                let n = rawBass.count
                var colorFloats = [Float]()
                colorFloats.reserveCapacity(n * 3)
                for i in 0..<n {
                    colorFloats.append(bassMax > 0 ? rawBass[i] / bassMax : 0)  // R
                    colorFloats.append(midMax  > 0 ? rawMid[i]  / midMax  : 0)  // G
                    colorFloats.append(highMax > 0 ? rawHigh[i] / highMax : 0)  // B
                }

                let colorsData = colorFloats.withUnsafeBytes { Data($0) }
                continuation.resume(returning: Result(peaks: normPeaks, colors: colorsData))
            }
        }
    }
}
