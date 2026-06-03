import AVFoundation
import Accelerate
import AudioToolbox

final class CancellationToken: @unchecked Sendable {
    nonisolated init() {}
    var isCancelled = false
}

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

    static func generate(filePath: String, targetBuckets: Int = 1000, token: CancellationToken = CancellationToken()) async -> Result? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Result?, Never>) in
            waveformQueue.async {
                guard !token.isCancelled else { continuation.resume(returning: nil); return }
                guard FileManager.default.fileExists(atPath: filePath) else {
                    continuation.resume(returning: nil); return
                }
                let url      = URL(fileURLWithPath: filePath)
                let baseName = url.lastPathComponent

                // ── 1. Open file ──────────────────────────────────────────────
                let t0 = Date()
                var extFile: ExtAudioFileRef?
                let openStatus = ExtAudioFileOpenURL(url as CFURL, &extFile)
                guard openStatus == noErr, let extFile else {
                    print("[WF-GEN] ExtAudioFileOpenURL failed (\(openStatus)) for \(baseName)")
                    continuation.resume(returning: nil); return
                }
                defer { ExtAudioFileDispose(extFile) }

                // ── 2. Read native format (sample rate + channel count) ────────
                var nativeFormat = AudioStreamBasicDescription()
                var fmtSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
                let fmtStatus = ExtAudioFileGetProperty(
                    extFile, kExtAudioFileProperty_FileDataFormat, &fmtSize, &nativeFormat)
                guard fmtStatus == noErr else {
                    print("[WF-GEN] FileDataFormat failed (\(fmtStatus)) for \(baseName)")
                    continuation.resume(returning: nil); return
                }
                let sampleRate   = nativeFormat.mSampleRate
                let channelCount = max(1, Int(nativeFormat.mChannelsPerFrame))

                // ── 3. Read total frame count ─────────────────────────────────
                var totalFrames: Int64 = 0
                var framesSize = UInt32(MemoryLayout<Int64>.size)
                let framesStatus = ExtAudioFileGetProperty(
                    extFile, kExtAudioFileProperty_FileLengthFrames, &framesSize, &totalFrames)
                guard framesStatus == noErr, totalFrames > 0 else {
                    print("[WF-GEN] FileLengthFrames failed or empty (\(framesStatus)) for \(baseName)")
                    continuation.resume(returning: nil); return
                }

                // ── 4 + 5. Set client format: Float32 non-interleaved ─────────
                // Requesting the file's native sample rate avoids an internal
                // sample-rate-conversion pass that would add ~2s per track.
                var clientFormat = AudioStreamBasicDescription()
                clientFormat.mSampleRate       = sampleRate
                clientFormat.mFormatID         = kAudioFormatLinearPCM
                clientFormat.mFormatFlags      = kAudioFormatFlagIsFloat
                                               | kAudioFormatFlagIsNonInterleaved
                clientFormat.mBytesPerPacket   = 4
                clientFormat.mFramesPerPacket  = 1
                clientFormat.mBytesPerFrame    = 4
                clientFormat.mChannelsPerFrame = UInt32(channelCount)
                clientFormat.mBitsPerChannel   = 32
                let clientStatus = ExtAudioFileSetProperty(
                    extFile, kExtAudioFileProperty_ClientDataFormat,
                    UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &clientFormat)
                guard clientStatus == noErr else {
                    print("[WF-GEN] ClientDataFormat set failed (\(clientStatus)) for \(baseName)")
                    continuation.resume(returning: nil); return
                }

                let t1 = Date()
                print("[WF-GEN] \(baseName) — file opened (\(totalFrames) frames @ \(Int(sampleRate)) Hz) in \(String(format: "%.3f", t1.timeIntervalSince(t0)))s")

                // ── FFT setup ─────────────────────────────────────────────────
                // Fixed 1024-point FFT — coarse band energy only, no need to
                // resolve individual bins. Snapshot from bucket centre avoids
                // the dynamic round-up (4096+) that scaled with track length.
                let framesPerBucket = max(1, Int(totalFrames) / targetBuckets)
                let fftSize = 1024
                let halfFFT = 512
                let log2n   = vDSP_Length(10)
                guard let fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
                    continuation.resume(returning: nil); return
                }
                defer { vDSP_destroy_fftsetup(fftSetup) }

                // Pre-compute Hz→bin boundaries.
                let hzPerBin = Float(sampleRate) / Float(fftSize)
                let bassLo = max(0,       Int(  20.0 / hzPerBin))
                let bassHi = min(halfFFT, Int( 250.0 / hzPerBin))
                let midLo  = bassHi
                let midHi  = min(halfFFT, Int(4000.0 / hzPerBin))
                let highLo = midHi
                let highHi = min(halfFFT, Int(20000.0 / hzPerBin))

                // Hann window — computed once, applied to every bucket.
                var hannWindow = [Float](repeating: 0, count: fftSize)
                vDSP_hann_window(&hannWindow, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))

                // Reusable per-bucket working buffers.
                var mono       = [Float](repeating: 0, count: fftSize)
                var realBuf    = [Float](repeating: 0, count: halfFFT)
                var imagBuf    = [Float](repeating: 0, count: halfFFT)
                var magnitudes = [Float](repeating: 0, count: halfFFT)

                // ── 6. Allocate channel buffers ───────────────────────────────
                // Read 512 buckets per ExtAudioFileRead call (~17–25 MB for stereo
                // float), reducing decode-API calls from 4,000 to ~8.
                let chunkBuckets   = 64
                let framesPerChunk = chunkBuckets * framesPerBucket

                // One Float32 buffer per channel — raw heap allocation so
                // ExtAudioFileRead can write directly without Swift bridging.
                var channelPtrs: [UnsafeMutablePointer<Float>] = (0..<channelCount).map { _ in
                    UnsafeMutablePointer<Float>.allocate(capacity: framesPerChunk)
                }
                defer { channelPtrs.forEach { $0.deallocate() } }

                // ── 7. Allocate AudioBufferList ───────────────────────────────
                // AudioBufferList.allocate(maximumBuffers:) is the idiomatic Swift
                // overlay for variable-length ABLs; it correctly sizes the struct
                // for channelCount AudioBuffer slots and returns a typed wrapper.
                var abl = AudioBufferList.allocate(maximumBuffers: channelCount)
                defer { abl.unsafeMutablePointer.deallocate() }
                abl.count = channelCount
                for ch in 0..<channelCount {
                    abl[ch] = AudioBuffer(
                        mNumberChannels: 1,
                        mDataByteSize:   UInt32(framesPerChunk * MemoryLayout<Float>.size),
                        mData:           UnsafeMutableRawPointer(channelPtrs[ch])
                    )
                }

                var peaks:   [Float] = []; peaks.reserveCapacity(targetBuckets + 4)
                var rawBass: [Float] = []; rawBass.reserveCapacity(targetBuckets + 4)
                var rawMid:  [Float] = []; rawMid.reserveCapacity(targetBuckets + 4)
                var rawHigh: [Float] = []; rawHigh.reserveCapacity(targetBuckets + 4)

                // ── 8. Main decode / analysis loop ────────────────────────────
                // Outer: one ExtAudioFileRead per chunk (≤8 calls for a 6-min track).
                // Inner: stride through the decoded chunk in memory — zero I/O per bucket.

                var done = false
                while !done {
                    if token.isCancelled { break }
                    // Reset mDataByteSize before each read — ExtAudioFileRead
                    // overwrites it with the actual bytes written.
                    for ch in 0..<channelCount {
                        abl[ch].mDataByteSize = UInt32(framesPerChunk * MemoryLayout<Float>.size)
                    }

                    var framesRead = UInt32(framesPerChunk)
                    let readStatus = ExtAudioFileRead(extFile, &framesRead, abl.unsafeMutablePointer)
                    guard readStatus == noErr else {
                        print("[WF-GEN] ExtAudioFileRead error \(readStatus) for \(baseName)")
                        break
                    }
                    guard framesRead > 0 else { break }  // EOF

                    let chunkFrames    = Int(framesRead)
                    let bucketsInChunk = chunkFrames / framesPerBucket
                    // Fewer frames than requested → last chunk, exit after this pass.
                    if framesRead < UInt32(framesPerChunk) { done = true }

                    for bucketIdx in 0..<bucketsInChunk {
                        if peaks.count >= targetBuckets + 4 { done = true; break }

                        let bucketStart = bucketIdx * framesPerBucket
                        let bucketEnd   = bucketStart + framesPerBucket
                        // All buckets within a chunk are fully in memory (floor
                        // division above guarantees bucketEnd ≤ chunkFrames).

                        // Amplitude peak — max abs across channels × frames.
                        var peak: Float = 0
                        for ch in 0..<channelCount {
                            let buf = channelPtrs[ch]
                            for i in bucketStart..<bucketEnd {
                                let v = abs(buf[i])
                                if v > peak { peak = v }
                            }
                        }
                        peaks.append(peak)

                        // Mix a centre snapshot (≤1024 frames) to mono for FFT.
                        // Taking from the bucket centre avoids transient bias at edges.
                        let snapshotLen   = min(framesPerBucket, fftSize)
                        let snapshotStart = framesPerBucket >= fftSize
                            ? framesPerBucket / 2 - fftSize / 2
                            : 0
                        vDSP_vclr(&mono, 1, vDSP_Length(fftSize))
                        for ch in 0..<channelCount {
                            let src = channelPtrs[ch]
                            for i in 0..<snapshotLen {
                                mono[i] += src[bucketStart + snapshotStart + i]
                            }
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
                    }
                }

                if token.isCancelled {
                    continuation.resume(returning: nil); return
                }
                guard !peaks.isEmpty else {
                    continuation.resume(returning: nil); return
                }
                let t2 = Date()
                print("[WF-GEN] \(baseName) — decode/FFT loop done in \(String(format: "%.3f", t2.timeIntervalSince(t1)))s, \(peaks.count) buckets")

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
                print("[WF-GEN] \(baseName) — normalization done in \(String(format: "%.3f", Date().timeIntervalSince(t2)))s, generate total \(String(format: "%.3f", Date().timeIntervalSince(t0)))s")
                continuation.resume(returning: Result(peaks: normPeaks, colors: colorsData))
            }
        }
    }
}
