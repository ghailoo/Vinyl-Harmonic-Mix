import Foundation

@Observable
final class SettingsViewModel {
    // MARK: - Discogs
    var token: String = ""
    var username: String = ""
    var isValidating = false
    var isTokenValidated = false
    var errorMessage: String? = nil
    var successMessage: String? = nil

    // MARK: - MusicBrainz
    var mbContactEmail: String = ""
    var mbIsTesting = false
    var mbSuccessMessage: String? = nil
    var mbErrorMessage: String? = nil

    private let keychain = KeychainService.shared
    private let client = DiscogsClient()
    private let mbClient = MusicBrainzClient()

    init() {
        token = keychain.load(for: .token) ?? ""
        username = keychain.load(for: .username) ?? ""
        mbContactEmail = keychain.load(for: .musicbrainzContactEmail) ?? ""
    }

    func save() {
        errorMessage = nil
        do {
            try keychain.save(token, for: .token)
            try keychain.save(username, for: .username)
            try keychain.save(mbContactEmail, for: .musicbrainzContactEmail)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func testToken() async {
        isValidating = true
        errorMessage = nil
        successMessage = nil
        defer { isValidating = false }
        do {
            let identity = try await client.validateToken(token)
            isTokenValidated = true
            successMessage = "Connected as @\(identity.username)"
        } catch {
            isTokenValidated = false
            errorMessage = error.localizedDescription
        }
    }

    func testMBConnection() async {
        mbIsTesting = true
        mbErrorMessage = nil
        mbSuccessMessage = nil
        defer { mbIsTesting = false }
        do {
            let latency = try await mbClient.testConnection(contactEmail: mbContactEmail)
            let ms = Int((latency * 1000).rounded())
            mbSuccessMessage = "Reachable · ~\(ms) ms"
        } catch {
            mbErrorMessage = "Unreachable: \(error.localizedDescription)"
        }
    }
}
