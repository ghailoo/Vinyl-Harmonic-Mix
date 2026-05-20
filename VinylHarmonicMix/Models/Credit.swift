import Foundation

struct Credit: Codable, Hashable, Identifiable {
    var id: String { "\(name)-\(role)" }
    let name: String
    let role: String
    let anv: String?
    let tracks: String?
    let resourceUrl: String?

    enum CodingKeys: String, CodingKey {
        case name, role, anv, tracks
        case resourceUrl = "resource_url"
    }
}
