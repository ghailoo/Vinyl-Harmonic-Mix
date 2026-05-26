import AVFoundation

enum WaveformGenerator {

    /// Reads an audio file off the main thread and returns ~`targetBuckets` normalized peak
    /// amplitude values (0…1). Returns nil if the file cannot be opened or is empty.
    static func generate(filePath: String, targetBuckets: Int = 4000) async -> [Float]? {
        await Task.detached(priority: .utility) { () -> [Float]? in
            guard FileManager.default.fileExists(atPath: filePath) else { return nil }
            let url = URL(fileURLWithPath: filePath)
            guard let file = try? AVAudioFile(forReading: url) else { return nil }

            let totalFrames = Int(file.length)
            guard totalFrames > 0 else { return nil }

            // How many source frames to accumulate into each output bucket
            let framesPerBucket = max(1, totalFrames / targetBuckets)
            let format = file.processingFormat      // always Float32 for AVAudioFile reads
            let channelCount = Int(format.channelCount)

            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(framesPerBucket)
            ) else { return nil }

            var peaks: [Float] = []
            peaks.reserveCapacity(targetBuckets + 4)

            while true {
                let framePosition = Int(file.framePosition)
                let remaining = totalFrames - framePosition
                guard remaining > 0 else { break }

                let toRead = min(AVAudioFrameCount(framesPerBucket), AVAudioFrameCount(remaining))
                buffer.frameLength = 0

                do {
                    try file.read(into: buffer, frameCount: toRead)
                } catch {
                    break
                }
                guard buffer.frameLength > 0 else { break }

                // Peak across all channels for this bucket
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

                if buffer.frameLength < toRead { break }   // reached EOF early
                if peaks.count >= targetBuckets + 4 { break }  // rounding slack
            }

            guard !peaks.isEmpty else { return nil }

            // Normalize so the loudest bucket = 1.0
            let maxPeak = peaks.max() ?? 1
            guard maxPeak > 0 else { return peaks }
            return peaks.map { $0 / maxPeak }
        }.value
    }
}
