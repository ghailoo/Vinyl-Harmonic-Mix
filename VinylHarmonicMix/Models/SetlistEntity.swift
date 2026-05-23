import SwiftData
import Foundation

@Model
final class SetlistEntity {
    @Attribute(.unique) var id: String
    var name: String
    var createdAt: Date
    var notes: String
    @Relationship(deleteRule: .cascade, inverse: \SetlistItemEntity.setlist)
    var items: [SetlistItemEntity] = []

    init(name: String = "Untitled Set") {
        self.id = UUID().uuidString
        self.name = name
        self.createdAt = .now
        self.notes = ""
    }
}
