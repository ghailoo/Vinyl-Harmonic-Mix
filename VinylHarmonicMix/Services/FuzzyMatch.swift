import Foundation

enum FuzzyMatch {
    nonisolated static func normalize(_ s: String) -> String {
        var t = s.lowercased()
        t = t.replacingOccurrences(of: #"\[[^\]]*\]"#, with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\([^\)]*\)"#, with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: " ii ", with: " 2 ")
        t = t.replacingOccurrences(of: #"[_\-\.,'""!?&]+"#, with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespaces)
    }

    nonisolated static func similarity(_ a: String, _ b: String) -> Double {
        let tA = Set(normalize(a).split(separator: " ").map(String.init))
        let tB = Set(normalize(b).split(separator: " ").map(String.init))
        return similarity(tokensA: tA, tokensB: tB)
    }

    nonisolated static func similarity(tokensA: Set<String>, tokensB: Set<String>) -> Double {
        if tokensA == tokensB { return 1.0 }
        guard !tokensA.isEmpty, !tokensB.isEmpty else { return 0 }
        let intersection = tokensA.intersection(tokensB).count
        let union = tokensA.union(tokensB).count
        return Double(intersection) / Double(union)
    }

    /// First 4 chars of normalized name, stripping leading articles
    nonisolated static func bucketKey(_ s: String) -> String {
        var n = normalize(s)
        for prefix in ["the ", "a ", "an "] {
            if n.hasPrefix(prefix) { n = String(n.dropFirst(prefix.count)); break }
        }
        return String(n.prefix(4))
    }

    /// Splits a normalized title into (baseTitle, versionToken).
    /// "Keep On Movin' (Club Mix)" → ("keep on movin", "club mix")
    /// "Rose Rouge" → ("rose rouge", nil)
    nonisolated static func splitVersion(_ title: String) -> (base: String, version: String?) {
        let norm = normalize(title)
        let pattern = #"[\(\[]\s*([^\)\]]*?(?:mix|remix|version|edit|dub|instrumental|radio|extended|vocal|7"|12"|rerub|rmx)[^\)\]]*?)\s*[\)\]]"#
        guard let matchRange = norm.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else {
            return (norm, nil)
        }
        let versionRaw = String(norm[matchRange])
            .trimmingCharacters(in: CharacterSet(charactersIn: "()[] "))
        let base = norm.replacingCharacters(in: matchRange, with: " ")
            .components(separatedBy: .whitespaces).filter { !$0.isEmpty }.joined(separator: " ")
        return (base, versionRaw.isEmpty ? nil : versionRaw)
    }

    /// Version similarity: 1.0 if both nil, 0.5 if one side missing, Jaccard if both present.
    nonisolated static func versionSimilarity(_ a: String?, _ b: String?) -> Double {
        switch (a, b) {
        case (nil, nil):           return 1.0
        case (nil, _), (_, nil):   return 0.5
        case let (.some(va), .some(vb)):
            let tA = Set(va.split(separator: " ").map(String.init))
            let tB = Set(vb.split(separator: " ").map(String.init))
            return similarity(tokensA: tA, tokensB: tB)
        }
    }
}
