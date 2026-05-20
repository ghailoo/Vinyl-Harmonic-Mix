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

// MARK: - URL-lookup response types

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

// MARK: - Search response types

private struct MBSearchResponse: Decodable {
    let releases: [MBSearchRelease]
}

private struct MBSearchRelease: Decodable {
    let id: String
    let score: Int
    let title: String
    let date: String?
    let country: String?
    let artistCredit: [MBSearchArtistCredit]?

    enum CodingKeys: String, CodingKey {
        case id, score, title, date, country
        case artistCredit = "artist-credit"
    }
}

private struct MBSearchArtistCredit: Decodable {
    let name: String?
}

// MARK: - Recordings response types

private struct MBReleaseRecordingsResponse: Decodable {
    let media: [MBMedium]
}

private struct MBMedium: Decodable {
    let tracks: [MBTrackItem]
}

private struct MBTrackItem: Decodable {
    let id: String
    let number: String?
    let position: Int
    let title: String
    let length: Int?
    let recording: MBRecordingItem
    let artistCredit: [MBArtistCredit]?

    enum CodingKeys: String, CodingKey {
        case id, number, position, title, length, recording
        case artistCredit = "artist-credit"
    }
}

private struct MBRecordingItem: Decodable {
    let id: String
    let title: String?
    let length: Int?
    let artistCredit: [MBArtistCredit]?

    enum CodingKeys: String, CodingKey {
        case id, title, length
        case artistCredit = "artist-credit"
    }
}

// MARK: - Public types

struct MBIDMatch {
    let mbid: String
    let title: String
    let artist: String
}

struct MBIDSearchMatch {
    let mbid: String
    let title: String
    let artist: String
    let score: Int
    let date: String?
    let country: String?
}

struct RecordingMBIDMatch {
    let trackMBID: String
    let recordingMBID: String
    let position: String
    let title: String
    let durationMs: Int?
    let artistCredit: String
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

    // MARK: - Lucene escaping

    private func escapeLucene(_ s: String) -> String {
        let special: Set<Character> = ["+", "-", "&", "|", "!", "(", ")", "{", "}", "[", "]",
                                       "^", "\"", "~", "*", "?", ":", "\\", "/"]
        return s.map { special.contains($0) ? "\\\($0)" : String($0) }.joined()
    }

    // MARK: - URL-lookup scan (rate-limited)

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
            return try parseURLMatch(from: data)
        case 404:
            return nil
        case 429, 503:
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            await rateLimiter.wait()
            let (retryData, retryResponse) = try await session.data(for: makeRequest(url))
            guard let retryHttp = retryResponse as? HTTPURLResponse, retryHttp.statusCode == 200 else {
                return nil
            }
            return try parseURLMatch(from: retryData)
        default:
            throw MBError.badResponse(http.statusCode)
        }
    }

    private func parseURLMatch(from data: Data) throws -> MBIDMatch? {
        let decoded = try JSONDecoder().decode(MBURLResponse.self, from: data)
        guard let release = decoded.relations.compactMap({ $0.release }).first else {
            return nil
        }
        let artistName = release.artistCredit?
            .compactMap { $0.name ?? $0.artist?.name }
            .joined(separator: " & ") ?? ""
        return MBIDMatch(mbid: release.id, title: release.title, artist: artistName)
    }

    // MARK: - Search-based fallback (rate-limited, same queue)

    func searchMBID(artist: String, title: String, year: Int?) async throws -> MBIDSearchMatch? {
        let escapedArtist = escapeLucene(artist)
        let escapedTitle = escapeLucene(title)
        var lucene = "artist:\"\(escapedArtist)\" AND release:\"\(escapedTitle)\""
        if let year, year > 0 {
            lucene += " AND date:\(year)"
        }
        guard let encoded = lucene.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://musicbrainz.org/ws/2/release?query=\(encoded)&limit=5&fmt=json") else {
            return nil
        }

        await rateLimiter.wait()
        return try await searchWithRetry(url: url)
    }

    private func searchWithRetry(url: URL) async throws -> MBIDSearchMatch? {
        let (data, response) = try await session.data(for: makeRequest(url))
        guard let http = response as? HTTPURLResponse else { return nil }

        switch http.statusCode {
        case 200:
            return try parseSearchMatch(from: data)
        case 429, 503:
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            await rateLimiter.wait()
            let (retryData, retryResponse) = try await session.data(for: makeRequest(url))
            guard let retryHttp = retryResponse as? HTTPURLResponse, retryHttp.statusCode == 200 else {
                return nil
            }
            return try parseSearchMatch(from: retryData)
        default:
            throw MBError.badResponse(http.statusCode)
        }
    }

    private func parseSearchMatch(from data: Data) throws -> MBIDSearchMatch? {
        let decoded = try JSONDecoder().decode(MBSearchResponse.self, from: data)
        guard let top = decoded.releases.first, top.score >= 90 else { return nil }
        let artistName = top.artistCredit?.compactMap(\.name).joined(separator: " ") ?? ""
        return MBIDSearchMatch(
            mbid: top.id,
            title: top.title,
            artist: artistName,
            score: top.score,
            date: top.date,
            country: top.country
        )
    }

    // MARK: - Recordings fetch (rate-limited, same queue)

    func fetchRecordings(forReleaseMBID mbid: String) async throws -> [RecordingMBIDMatch] {
        let urlString = "https://musicbrainz.org/ws/2/release/\(mbid)?inc=recordings+artist-credits&fmt=json"
        guard let url = URL(string: urlString) else { throw MBError.badResponse(0) }
        await rateLimiter.wait()
        return try await fetchRecordingsWithRetry(url: url)
    }

    private func fetchRecordingsWithRetry(url: URL) async throws -> [RecordingMBIDMatch] {
        let (data, response) = try await session.data(for: makeRequest(url))
        guard let http = response as? HTTPURLResponse else { throw MBError.badResponse(0) }
        switch http.statusCode {
        case 200:
            return try parseRecordings(from: data)
        case 404:
            throw MBError.badResponse(404)
        case 429, 503:
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            await rateLimiter.wait()
            let (retryData, retryResponse) = try await session.data(for: makeRequest(url))
            guard let retryHttp = retryResponse as? HTTPURLResponse, retryHttp.statusCode == 200 else {
                throw MBError.badResponse((retryResponse as? HTTPURLResponse)?.statusCode ?? 0)
            }
            return try parseRecordings(from: retryData)
        default:
            throw MBError.badResponse(http.statusCode)
        }
    }

    private func parseRecordings(from data: Data) throws -> [RecordingMBIDMatch] {
        let decoded = try JSONDecoder().decode(MBReleaseRecordingsResponse.self, from: data)
        var results: [RecordingMBIDMatch] = []
        for medium in decoded.media {
            for track in medium.tracks {
                let position = track.number ?? String(track.position)
                let credits = (track.artistCredit ?? track.recording.artistCredit)?
                    .compactMap { $0.name ?? $0.artist?.name }
                    .joined(separator: " & ") ?? ""
                results.append(RecordingMBIDMatch(
                    trackMBID: track.id,
                    recordingMBID: track.recording.id,
                    position: position,
                    title: track.title,
                    durationMs: track.length ?? track.recording.length,
                    artistCredit: credits
                ))
            }
        }
        return results
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
