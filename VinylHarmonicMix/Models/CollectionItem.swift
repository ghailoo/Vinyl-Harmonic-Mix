import Foundation

struct CollectionItem: Codable, Identifiable, Hashable {
    let id: Int              // instance_id (unique per copy)
    let releaseId: Int       // Discogs release id, for /releases/{id}
    let folderId: Int
    let rating: Int
    let dateAdded: String
    let basicInformation: BasicInformation

    enum CodingKeys: String, CodingKey {
        case id = "instance_id"
        case releaseId = "id"
        case folderId = "folder_id"
        case rating
        case dateAdded = "date_added"
        case basicInformation = "basic_information"
    }
}
