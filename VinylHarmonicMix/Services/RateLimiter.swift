import Foundation

actor RateLimiter {
    static let shared = RateLimiter()

    private var lastRequestDate: Date = .distantPast
    private let minimumInterval: TimeInterval = 1.1

    private init() {}

    func waitForSlot() async throws {
        let elapsed = Date().timeIntervalSince(lastRequestDate)
        if elapsed < minimumInterval {
            try await Task.sleep(for: .seconds(minimumInterval - elapsed))
        }
        lastRequestDate = Date()
    }
}
