import Foundation

struct DiscogsIdentity: Codable {
    let id: Int
    let username: String
    let resourceUrl: String
    let consumerName: String

    enum CodingKeys: String, CodingKey {
        case id, username
        case resourceUrl = "resource_url"
        case consumerName = "consumer_name"
    }
}
