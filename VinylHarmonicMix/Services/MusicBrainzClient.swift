import Foundation

// MARK: - Rate limiter

private actor MBRateLimiter {
    private var lastRequestDate: Date = .distantPast

    func wait() async {
        let elapsed = Date().timeIntervalSince(lastRequestDate)
        let gap = 1.05
        if elapsed < gap {
            try? await Task.sleep(nanoseconds: UInt64((gap - elapsed) * 1_000_000_000))
        }
        lastRequestDate = Date()
    }
}

// MARK: - Response types

private struct MBURLResponse: Decodable {
    let relations: [MBRelation]
}

private struct MBRelation: Decodable {
    let release: MBRelease?
}

private struct MBRelease: Decodable {
    let id: String
    let title: String
    let artistCredit: [MBArtistCredit]?

    enum CodingKeys: String, CodingKey {
        case id, title
        case artistCredit = "artist-credit"
    }
}

private struct MBArtistCredit: Decodable {
    let name: String?
    let artist: MBArtist?
}

private struct MBArtist: Decodable {
    let name: String
}

// MARK: - Public types

struct MBIDMatch {
    let mbid: String
    let title: String
    let artist: String
}

enum MBError: LocalizedError {
    case badResponse(Int)

    var errorDescription: String? {
        switch self {
        case .badResponse(let code): return "MusicBrainz returned HTTP \(code)"
        }
    }
}

// MARK: - Client

final class MusicBrainzClient {
    private let rateLimiter = MBRateLimiter()
    private let session = URLSession(configuration: .default)

    private var userAgent: String {
        let stored = KeychainService.shared.load(for: .musicbrainzContactEmail) ?? ""
        let email = stored.isEmpty ? "vinylharmonicmix-dev@example.com" : stored
        return "VinylHarmonicMix/1.0 ( \(email) )"
    }

    private func makeRequest(_ url: URL) -> URLRequest {
        var req = URLRequest(url: url)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        return req
    }

    // MARK: - Scan lookup (rate-limited)

    func findMBID(forDiscogsReleaseId releaseId: Int) async throws -> MBIDMatch? {
        let urlString = "https://musicbrainz.org/ws/2/url?resource=https://www.discogs.com/release/\(releaseId)&inc=release-rels&fmt=json"
        guard let url = URL(string: urlString) else { return nil }

        await rateLimiter.wait()
        return try await fetchWithRetry(url: url)
    }

    private func fetchWithRetry(url: URL) async throws -> MBIDMatch? {
        let (data, response) = try await session.data(for: makeRequest(url))
        guard let http = response as? HTTPURLResponse else { return nil }

        switch http.statusCode {
        case 200:
            return try parseMBIDMatch(from: data)

        case 404:
            return nil

        case 429, 503:
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            await rateLimiter.wait()
            let (retryData, retryResponse) = try await session.data(for: makeRequest(url))
            guard let retryHttp = retryResponse as? HTTPURLResponse, retryHttp.statusCode == 200 else {
                return nil
            }
            return try parseMBIDMatch(from: retryData)

        default:
            throw MBError.badResponse(http.statusCode)
        }
    }

    private func parseMBIDMatch(from data: Data) throws -> MBIDMatch? {
        let decoded = try JSONDecoder().decode(MBURLResponse.self, from: data)
        guard let release = decoded.relations.compactMap({ $0.release }).first else {
            return nil
        }
        let artistName = release.artistCredit?
            .compactMap { $0.name ?? $0.artist?.name }
            .joined(separator: " & ") ?? ""
        return MBIDMatch(mbid: release.id, title: release.title, artist: artistName)
    }

    // MARK: - Connectivity test (not rate-limited)

    func testConnection(contactEmail: String) async throws -> TimeInterval {
        let email = contactEmail.isEmpty ? "vinylharmonicmix-dev@example.com" : contactEmail
        let ua = "VinylHarmonicMix/1.0 ( \(email) )"
        guard let url = URL(string: "https://musicbrainz.org/ws/2/release/76df3287-6cda-33eb-8e9a-044b5e15ffdd?fmt=json") else {
            throw MBError.badResponse(0)
        }
        var request = URLRequest(url: url)
        request.setValue(ua, forHTTPHeaderField: "User-Agent")

        let start = Date()
        let (_, response) = try await session.data(for: request)
        let duration = Date().timeIntervalSince(start)

        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw MBError.badResponse((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return duration
    }
}
