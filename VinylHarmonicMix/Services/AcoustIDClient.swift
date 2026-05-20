import Foundation

private actor ThrottleQueue {
    private let interval: TimeInterval
    private var lastRequest: Date = .distantPast

    init(intervalSeconds: TimeInterval) { self.interval = intervalSeconds }

    func wait() async {
        let elapsed = Date().timeIntervalSince(lastRequest)
        if elapsed < interval {
            try? await Task.sleep(nanoseconds: UInt64((interval - elapsed) * 1_000_000_000))
        }
        lastRequest = Date()
    }
}

actor AcoustIDClient {
    private let throttle = ThrottleQueue(intervalSeconds: 0.34)
    private let session = URLSession.shared
    private let fpcalcPath: String
    private let apiKey: String

    struct FingerprintResult {
        let duration: Int
        let fingerprint: String
    }

    struct LookupResult {
        let recordingMBIDs: [String]
        let topScore: Double
    }

    init(fpcalcPath: String, apiKey: String) {
        self.fpcalcPath = fpcalcPath
        self.apiKey = apiKey
    }

    func fingerprint(filePath: String) async throws -> FingerprintResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: fpcalcPath)
        process.arguments = ["-json", filePath]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw AcoustIDError.fingerprintFailed(filePath)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let duration = json["duration"] as? Double,
              let fp = json["fingerprint"] as? String else {
            throw AcoustIDError.fingerprintParseFailed
        }
        return FingerprintResult(duration: Int(duration), fingerprint: fp)
    }

    func lookup(fingerprint: String, duration: Int) async throws -> LookupResult {
        await throttle.wait()
        var request = URLRequest(url: URL(string: "https://api.acoustid.org/v2/lookup")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = "client=\(apiKey)&duration=\(duration)&fingerprint=\(fingerprint)&meta=recordings"
        request.httpBody = body.data(using: .utf8)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AcoustIDError.invalidResponse }
        if http.statusCode == 429 {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            return try await lookup(fingerprint: fingerprint, duration: duration)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw AcoustIDError.httpError(http.statusCode)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AcoustIDError.invalidResponse
        }
        if let err = json["error"] as? [String: Any] {
            throw AcoustIDError.apiError(err["message"] as? String ?? "unknown")
        }
        var mbids: [String] = []
        var topScore = 0.0
        if let results = json["results"] as? [[String: Any]] {
            for result in results {
                let score = result["score"] as? Double ?? 0.0
                topScore = max(topScore, score)
                if let recordings = result["recordings"] as? [[String: Any]] {
                    for rec in recordings {
                        if let id = rec["id"] as? String { mbids.append(id) }
                    }
                }
            }
        }
        return LookupResult(recordingMBIDs: mbids, topScore: topScore)
    }
}

enum AcoustIDError: LocalizedError {
    case fingerprintFailed(String), fingerprintParseFailed
    case invalidResponse, httpError(Int), apiError(String)

    var errorDescription: String? {
        switch self {
        case .fingerprintFailed(let p): return "fpcalc failed on \(p)"
        case .fingerprintParseFailed:   return "Could not parse fpcalc JSON output"
        case .invalidResponse:          return "Invalid AcoustID response"
        case .httpError(let c):         return "HTTP \(c) from AcoustID"
        case .apiError(let m):          return "AcoustID API error: \(m)"
        }
    }
}
