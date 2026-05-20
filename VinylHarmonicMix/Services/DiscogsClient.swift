import Foundation

final class DiscogsClient {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - Public API

    func validateToken(_ token: String) async throws -> DiscogsIdentity {
        guard let url = URL(string: "https://api.discogs.com/oauth/identity") else {
            throw DiscogsError.invalidResponse
        }
        let (data, http) = try await execute(authorizedRequest(url: url, token: token))
        switch http.statusCode {
        case 200: return try decode(DiscogsIdentity.self, from: data)
        case 401: throw DiscogsError.unauthorized
        default:  throw DiscogsError.httpError(http.statusCode)
        }
    }

    func fetchCollection(
        username: String,
        token: String,
        onProgress: ((Int, Int) -> Void)? = nil
    ) async throws -> [CollectionItem] {
        var all: [CollectionItem] = []
        var page = 1
        var totalPages = 1

        repeat {
            guard let url = collectionURL(username: username, page: page) else {
                throw DiscogsError.invalidResponse
            }
            let (data, http) = try await execute(authorizedRequest(url: url, token: token))
            guard http.statusCode == 200 else { throw DiscogsError.httpError(http.statusCode) }

#if DEBUG
            if page == 1 {
                if let obj = try? JSONSerialization.jsonObject(with: data),
                   let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
                   let str = String(data: pretty, encoding: .utf8) {
                    print("=== Discogs collection page 1 raw JSON ===")
                    print(str.prefix(4000))
                    print("=== end ===")
                }
            }
#endif

            let response: CollectionResponse
            do {
                response = try Self.makeDecoder().decode(CollectionResponse.self, from: data)
            } catch let DecodingError.keyNotFound(key, ctx) {
                print("❌ Missing key: \(key.stringValue) — path: \(ctx.codingPath.map(\.stringValue).joined(separator: "."))")
                throw DiscogsError.decodingFailed(DecodingError.keyNotFound(key, ctx))
            } catch let DecodingError.typeMismatch(type, ctx) {
                print("❌ Type mismatch: expected \(type) — path: \(ctx.codingPath.map(\.stringValue).joined(separator: "."))")
                throw DiscogsError.decodingFailed(DecodingError.typeMismatch(type, ctx))
            } catch let DecodingError.valueNotFound(type, ctx) {
                print("❌ Value not found: \(type) — path: \(ctx.codingPath.map(\.stringValue).joined(separator: "."))")
                throw DiscogsError.decodingFailed(DecodingError.valueNotFound(type, ctx))
            } catch {
                print("❌ Decode error: \(error)")
                throw DiscogsError.decodingFailed(error)
            }

            totalPages = response.pagination.pages
            all.append(contentsOf: response.releases)
            onProgress?(page, totalPages)
            page += 1
        } while page <= totalPages

        return all
    }

    func fetchReleaseDetail(id: Int, token: String) async throws -> ReleaseDetail {
        guard let url = URL(string: "https://api.discogs.com/releases/\(id)") else {
            throw DiscogsError.invalidResponse
        }
        let (data, http) = try await execute(authorizedRequest(url: url, token: token))
        guard http.statusCode == 200 else { throw DiscogsError.httpError(http.statusCode) }
        return try decode(ReleaseDetail.self, from: data)
    }

    // MARK: - Private helpers

    private func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await RateLimiter.shared.waitForSlot()
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw DiscogsError.invalidResponse }

        if http.statusCode == 429 {
            try await Task.sleep(for: .seconds(5))
            try await RateLimiter.shared.waitForSlot()
            let (retryData, retryResponse) = try await session.data(for: request)
            guard let retryHttp = retryResponse as? HTTPURLResponse else {
                throw DiscogsError.invalidResponse
            }
            return (retryData, retryHttp)
        }
        return (data, http)
    }

    private func authorizedRequest(url: URL, token: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("Discogs token=\(token)", forHTTPHeaderField: "Authorization")
        request.setValue("VinylHarmonicMix/1.0 +https://example.com", forHTTPHeaderField: "User-Agent")
        return request
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try Self.makeDecoder().decode(type, from: data)
        } catch {
            throw DiscogsError.decodingFailed(error)
        }
    }

    private static func makeDecoder() -> JSONDecoder {
        // No key decoding strategy — every Codable model declares explicit CodingKeys.
        JSONDecoder()
    }

    private func collectionURL(username: String, page: Int) -> URL? {
        var components = URLComponents(string: "https://api.discogs.com/users/\(username)/collection/folders/0/releases")
        components?.queryItems = [
            URLQueryItem(name: "per_page", value: "100"),
            URLQueryItem(name: "page", value: "\(page)"),
        ]
        return components?.url
    }
}

// MARK: - Private response envelope

private struct CollectionResponse: Decodable {
    let pagination: Pagination
    let releases: [CollectionItem]

    struct Pagination: Decodable {
        let page: Int
        let pages: Int
    }
}
