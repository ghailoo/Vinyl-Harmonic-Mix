import SwiftData

@Model
final class FormatEntity {
    var name: String
    var qty: String
    var descriptions: [String]?

    init(name: String, qty: String, descriptions: [String]?) {
        self.name = name
        self.qty = qty
        self.descriptions = descriptions
    }
}
