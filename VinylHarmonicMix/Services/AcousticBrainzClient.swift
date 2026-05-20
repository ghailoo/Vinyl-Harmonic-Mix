import Foundation

actor AcousticBrainzClient {
    private let throttle = ABThrottleQueue(intervalSeconds: 1.1)
    private let session = URLSession.shared

    struct FeaturesBatch {
        let results: [String: RecordingFeatures]
        let missing: [String]
    }

    struct RecordingFeatures {
        let bpm: Double?
        let keyNote: String?
        let keyScale: String?
        let keyConfidence: Double?
        let danceabilityValue: Double?
        let moodHappy: String?
        let moodPartyProb: Double?
        let moodElectronicProb: Double?
        let moodAcousticProb: Double?
        let danceabilityLabel: String?
        let danceabilityProb: Double?
        let genreDortmund: String?
    }

    struct LowLevelFeatures {
        let bpm: Double?
        let keyNote: String?
        let keyScale: String?
        let keyConfidence: Double?
    }

    struct LowLevelBatch {
        let results: [String: LowLevelFeatures]
        let missing: [String]
    }

    func fetchFeatures(recordingMBIDs: [String], isRetry: Bool = false) async throws -> FeaturesBatch {
        guard recordingMBIDs.count <= 25 else {
            throw AcousticBrainzError.tooManyMBIDs(recordingMBIDs.count)
        }

        await throttle.wait()

        let mbidParam = recordingMBIDs.joined(separator: ";")
        var components = URLComponents(string: "https://acousticbrainz.org/api/v1/high-level")!
        components.queryItems = [URLQueryItem(name: "recording_ids", value: mbidParam)]
        guard let url = components.url else {
            throw AcousticBrainzError.invalidURL
        }

        var request = URLRequest(url: url)
        request.setValue("VinylHarmonicMix/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let httpResp = response as? HTTPURLResponse else {
            throw AcousticBrainzError.invalidResponse
        }

        if httpResp.statusCode == 429 || httpResp.statusCode == 503 {
            guard !isRetry else {
                throw AcousticBrainzError.httpError(statusCode: httpResp.statusCode)
            }
            try await Task.sleep(nanoseconds: 5_000_000_000)
            return try await fetchFeatures(recordingMBIDs: recordingMBIDs, isRetry: true)
        }

        guard (200..<300).contains(httpResp.statusCode) else {
            throw AcousticBrainzError.httpError(statusCode: httpResp.statusCode)
        }

        return try parseResponse(data: data, requestedMBIDs: recordingMBIDs)
    }

    private func parseResponse(data: Data, requestedMBIDs: [String]) throws -> FeaturesBatch {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AcousticBrainzError.invalidResponse
        }

        var results: [String: RecordingFeatures] = [:]

        for mbid in requestedMBIDs {
            let key = mbid.lowercased()
            guard let mbidEntry = json[key] as? [String: Any],
                  let offsetZero = mbidEntry["0"] as? [String: Any] else { continue }
            results[key] = extractFeatures(from: offsetZero)
        }

        let foundKeys = Set(results.keys)
        let missing = requestedMBIDs.filter { !foundKeys.contains($0.lowercased()) }

        return FeaturesBatch(results: results, missing: missing)
    }

    private func extractFeatures(from doc: [String: Any]) -> RecordingFeatures {
        let rhythm    = doc["rhythm"]    as? [String: Any]
        let tonal     = doc["tonal"]     as? [String: Any]
        let highlevel = doc["highlevel"] as? [String: Any]

        let bpm               = rhythm?["bpm"]          as? Double
        let danceabilityValue = rhythm?["danceability"]  as? Double

        let keyNote       = tonal?["key_key"]      as? String
        let keyScale      = tonal?["key_scale"]    as? String
        let keyConfidence = tonal?["key_strength"] as? Double

        func hlValue(_ key: String) -> String? {
            (highlevel?[key] as? [String: Any])?["value"] as? String
        }
        func hlProb(_ key: String) -> Double? {
            (highlevel?[key] as? [String: Any])?["probability"] as? Double
        }

        return RecordingFeatures(
            bpm: bpm,
            keyNote: keyNote,
            keyScale: keyScale,
            keyConfidence: keyConfidence,
            danceabilityValue: danceabilityValue,
            moodHappy: hlValue("mood_happy"),
            moodPartyProb: hlProb("mood_party"),
            moodElectronicProb: hlProb("mood_electronic"),
            moodAcousticProb: hlProb("mood_acoustic"),
            danceabilityLabel: hlValue("danceability"),
            danceabilityProb: hlProb("danceability"),
            genreDortmund: hlValue("genre_dortmund")
        )
    }

    // MARK: - Low-level endpoint (BPM and key)

    func fetchLowLevel(recordingMBIDs: [String], isRetry: Bool = false) async throws -> LowLevelBatch {
        guard recordingMBIDs.count <= 25 else {
            throw AcousticBrainzError.tooManyMBIDs(recordingMBIDs.count)
        }

        await throttle.wait()

        let mbidParam = recordingMBIDs.joined(separator: ";")
        var components = URLComponents(string: "https://acousticbrainz.org/api/v1/low-level")!
        components.queryItems = [URLQueryItem(name: "recording_ids", value: mbidParam)]
        guard let url = components.url else {
            throw AcousticBrainzError.invalidURL
        }

        var request = URLRequest(url: url)
        request.setValue("VinylHarmonicMix/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let httpResp = response as? HTTPURLResponse else {
            throw AcousticBrainzError.invalidResponse
        }

        if httpResp.statusCode == 429 || httpResp.statusCode == 503 {
            guard !isRetry else {
                throw AcousticBrainzError.httpError(statusCode: httpResp.statusCode)
            }
            try await Task.sleep(nanoseconds: 5_000_000_000)
            return try await fetchLowLevel(recordingMBIDs: recordingMBIDs, isRetry: true)
        }

        guard (200..<300).contains(httpResp.statusCode) else {
            throw AcousticBrainzError.httpError(statusCode: httpResp.statusCode)
        }

        return try parseLowLevelResponse(data: data, requestedMBIDs: recordingMBIDs)
    }

    private func parseLowLevelResponse(data: Data, requestedMBIDs: [String]) throws -> LowLevelBatch {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AcousticBrainzError.invalidResponse
        }

        var results: [String: LowLevelFeatures] = [:]

        for mbid in requestedMBIDs {
            let key = mbid.lowercased()
            guard let mbidEntry = json[key] as? [String: Any],
                  let offsetZero = mbidEntry["0"] as? [String: Any] else { continue }
            results[key] = extractLowLevelFeatures(from: offsetZero)
        }

        let foundKeys = Set(results.keys)
        let missing = requestedMBIDs.filter { !foundKeys.contains($0.lowercased()) }

        return LowLevelBatch(results: results, missing: missing)
    }

    private func extractLowLevelFeatures(from doc: [String: Any]) -> LowLevelFeatures {
        let rhythm = doc["rhythm"] as? [String: Any]
        let tonal  = doc["tonal"]  as? [String: Any]

        return LowLevelFeatures(
            bpm:          rhythm?["bpm"]          as? Double,
            keyNote:      tonal?["key_key"]        as? String,
            keyScale:     tonal?["key_scale"]      as? String,
            keyConfidence: tonal?["key_strength"]  as? Double
        )
    }
}

enum AcousticBrainzError: LocalizedError {
    case tooManyMBIDs(Int)
    case invalidURL
    case invalidResponse
    case httpError(statusCode: Int)

    var errorDescription: String? {
        switch self {
        case .tooManyMBIDs(let n): return "Requested \(n) MBIDs; max is 25 per request."
        case .invalidURL:          return "Invalid URL for AcousticBrainz request."
        case .invalidResponse:     return "Could not parse AcousticBrainz response."
        case .httpError(let code): return "AcousticBrainz returned HTTP \(code)."
        }
    }
}

// Separate throttle queue for AcousticBrainz; MusicBrainz uses its own RateLimiter.
actor ABThrottleQueue {
    private let intervalSeconds: Double
    private var lastRequestTime: Date?

    init(intervalSeconds: Double) {
        self.intervalSeconds = intervalSeconds
    }

    func wait() async {
        if let last = lastRequestTime {
            let elapsed = Date().timeIntervalSince(last)
            let waitTime = max(0, intervalSeconds - elapsed)
            if waitTime > 0 {
                try? await Task.sleep(nanoseconds: UInt64(waitTime * 1_000_000_000))
            }
        }
        lastRequestTime = Date()
    }
}
