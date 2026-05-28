import AVFoundation

enum WaveformGenerator {

    // Dedicated serial GCD queue — completely isolated from the Swift cooperative
    // pool, so a full-file NAS read never blocks a MainActor hop or UI update.
    private static let waveformQueue = DispatchQueue(
        label: "com.vinylharmonic.waveform", qos: .utility)

    static func generate(filePath: String, targetBuckets: Int = 4000) async -> [Float]? {
        await withCheckedContinuation { (continuation: CheckedContinuation<[Float]?, Never>) in
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
                let format      = file.processingFormat
                let channelCount = Int(format.channelCount)

                guard let buffer = AVAudioPCMBuffer(
                    pcmFormat: format,
                    frameCapacity: AVAudioFrameCount(framesPerBucket)
                ) else {
                    continuation.resume(returning: nil); return
                }

                var peaks: [Float] = []
                peaks.reserveCapacity(targetBuckets + 4)

                while true {
                    let framePosition = Int(file.framePosition)
                    let remaining = totalFrames - framePosition
                    guard remaining > 0 else { break }

                    let toRead = min(AVAudioFrameCount(framesPerBucket),
                                    AVAudioFrameCount(remaining))
                    buffer.frameLength = 0
                    do { try file.read(into: buffer, frameCount: toRead) } catch { break }
                    guard buffer.frameLength > 0 else { break }

                    var peak: Float = 0
                    for ch in 0..<channelCount {
                        guard let data = buffer.floatChannelData?[ch] else { continue }
                        let frameCount = Int(buffer.frameLength)
                        for i in 0..<frameCount {
                            let v = abs(data[i])
                            if v > peak { peak = v }
                        }
                    }
                    peaks.append(peak)

                    if buffer.frameLength < toRead { break }
                    if peaks.count >= targetBuckets + 4 { break }
                }

                guard !peaks.isEmpty else {
                    continuation.resume(returning: nil); return
                }
                let maxPeak = peaks.max() ?? 1
                guard maxPeak > 0 else {
                    continuation.resume(returning: peaks); return
                }
                continuation.resume(returning: peaks.map { $0 / maxPeak })
            }
        }
    }
}
