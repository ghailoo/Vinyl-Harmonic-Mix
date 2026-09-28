import Foundation

nonisolated struct Identifier: Codable, Hashable {
    let type: String
    let value: String
    let description: String?
}
