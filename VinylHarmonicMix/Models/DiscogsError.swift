import Foundation

enum DiscogsError: LocalizedError {
    case invalidResponse
    case missingToken
    case unauthorized
    case httpError(Int)
    case decodingFailed(Error)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Received an invalid response from the Discogs API."
        case .missingToken:
            return "VinylHarmonicMix needs a Discogs token. Add your Personal Access Token and username in Settings to load your collection and release details."
        case .unauthorized:
            return "Discogs rejected the token — it has probably expired or been revoked. Generate a new one on discogs.com under Settings → Developers."
        case .httpError(let code):
            return "Discogs API returned HTTP \(code)."
        case .decodingFailed(let error):
            return "Failed to decode response: \(error.localizedDescription)"
        }
    }
}
