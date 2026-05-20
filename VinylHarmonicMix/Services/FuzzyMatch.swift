import Foundation

enum FuzzyMatch {
    static func normalize(_ s: String) -> String {
        var t = s.lowercased()
        t = t.replacingOccurrences(of: #"\[[^\]]*\]"#, with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\([^\)]*\)"#, with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: " ii ", with: " 2 ")
        t = t.replacingOccurrences(of: #"[_\-\.,'""!?&]+"#, with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespaces)
    }

    static func similarity(_ a: String, _ b: String) -> Double {
        let na = normalize(a), nb = normalize(b)
        if na == nb { return 1.0 }
        let tokensA = Set(na.split(separator: " ").map(String.init))
        let tokensB = Set(nb.split(separator: " ").map(String.init))
        guard !tokensA.isEmpty, !tokensB.isEmpty else { return 0 }
        let intersection = tokensA.intersection(tokensB).count
        let union = tokensA.union(tokensB).count
        return Double(intersection) / Double(union)
    }

    /// First 4 chars of normalized name, stripping leading articles
    static func bucketKey(_ s: String) -> String {
        var n = normalize(s)
        for prefix in ["the ", "a ", "an "] {
            if n.hasPrefix(prefix) { n = String(n.dropFirst(prefix.count)); break }
        }
        return String(n.prefix(4))
    }
}
