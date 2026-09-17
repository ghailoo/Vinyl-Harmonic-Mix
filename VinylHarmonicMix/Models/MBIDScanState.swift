enum MBIDScanState: String {
    case unscanned
    case matched
    case notFound
    case failed
    case matchedViaSearch
    case matchedManually
    case needsReview
}

/// How a `.matchedViaSearch` result was found — `.matched` (URL relationship) doesn't need
/// this since it's a single strategy; search-pipeline strategies (B) are broken out for C2's
/// per-method counts.
enum MBIDMatchMethod: String, Codable {
    case barcode
    case catalogNumber
    case search
    case masterLookup
}
