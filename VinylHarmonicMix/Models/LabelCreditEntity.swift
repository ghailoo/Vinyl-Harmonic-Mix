import SwiftData

@Model
final class LabelCreditEntity {
    var name: String
    var catno: String

    init(name: String, catno: String) {
        self.name = name
        self.catno = catno
    }
}
