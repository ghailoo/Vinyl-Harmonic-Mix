import Foundation

enum CollectionSort: String, CaseIterable, Identifiable {
    case artistAsc  = "Artist (A → Z)"
    case artistDesc = "Artist (Z → A)"
    case titleAsc   = "Title (A → Z)"
    case titleDesc  = "Title (Z → A)"
    case yearDesc   = "Year (newest first)"
    case yearAsc    = "Year (oldest first)"
    case addedDesc  = "Recently added"
    case addedAsc   = "Added (oldest first)"
    case ratingDesc = "Rating (highest first)"
    case labelAsc   = "Label (A → Z)"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .artistAsc, .artistDesc:   return "person"
        case .titleAsc, .titleDesc:     return "textformat"
        case .yearDesc, .yearAsc:       return "calendar"
        case .addedDesc, .addedAsc:     return "clock"
        case .ratingDesc:               return "star"
        case .labelAsc:                 return "tag"
        }
    }
}

enum CollectionFilter: String, CaseIterable, Identifiable {
    case all       = "All"
    case matched   = "Matched"
    case notFound  = "Not found"
    case failed    = "Failed"
    case unscanned = "Unscanned"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .all:      return "circle.grid.2x2"
        case .matched:  return "checkmark.seal.fill"
        case .notFound: return "questionmark.circle"
        case .failed:   return "exclamationmark.triangle"
        case .unscanned: return "circle.dotted"
        }
    }
}
