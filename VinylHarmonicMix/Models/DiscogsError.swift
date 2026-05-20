import Foundation

enum DiscogsError: LocalizedError {
    case invalidResponse
    case unauthorized
    case httpError(Int)
    case decodingFailed(Error)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Received an invalid response from the Discogs API."
        case .unauthorized:
            return "Invalid token. Check your Discogs Personal Access Token."
        case .httpError(let code):
            return "Discogs API returned HTTP \(code)."
        case .decodingFailed(let error):
            return "Failed to decode response: \(error.localizedDescription)"
        }
    }
}
