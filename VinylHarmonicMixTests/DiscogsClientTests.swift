//
//  DiscogsClientTests.swift
//  VinylHarmonicMixTests
//
//  A 401 from any Discogs endpoint must surface as .unauthorized (the "expired or
//  revoked token" message), not a bare "HTTP 401".
//

import Foundation
import Testing
@testable import VinylHarmonicMix

/// Answers every request with HTTP 401.
private final class Always401: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data())
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

struct DiscogsClientTests {

    @MainActor @Test func rejectedTokenIsUnauthorizedOnEveryEndpoint() async {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Always401.self]
        let client = DiscogsClient(session: URLSession(configuration: config))

        for call in [
            { _ = try await client.fetchReleaseDetail(id: 1, token: "x") },
            { _ = try await client.fetchCollection(username: "u", token: "x") },
            { _ = try await client.fetchCollectionInstanceIDs(username: "u", token: "x") },
        ] as [() async throws -> Void] {
            do { try await call(); Issue.record("expected a throw") }
            catch DiscogsError.unauthorized {}
            catch { Issue.record("expected .unauthorized, got \(error)") }
        }
    }
}
