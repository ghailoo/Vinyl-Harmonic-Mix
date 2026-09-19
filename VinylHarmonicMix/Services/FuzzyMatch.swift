import Foundation

enum FuzzyMatch {

    // Single source of truth for "is this the same mix/version" — shared by
    // FileMatchCoordinator's confident/review tiering and FileMatchesView's mixCheck so the
    // two never disagree about the same versionSimilarity score.
    nonisolated static let versionMatchThreshold = 0.6

    // Stripped before comparing version tokens — these words carry no distinguishing info.
    // "Dime and Dollar mix" → {dime, dollar}; "Original Radio Mix" → {original, radio}
    private static let versionFillerWords: Set<String> = [
        "mix", "remix", "version", "ver", "vers", "edit", "re", "the", "a", "and"
    ]

    nonisolated static func normalize(_ s: String) -> String {
        var t = s.lowercased()
        t = t.replacingOccurrences(of: #"\[[^\]]*\]"#, with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\([^\)]*\)"#, with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: " ii ", with: " 2 ")
        // Strip apostrophes without inserting a space so "wasn't" → "wasnt" not "wasn t".
        // Must handle both straight (U+0027) and curly (U+2018/U+2019) variants —
        // MusicBrainz titles use curly; filenames use straight; mismatched tokens kill narrowing.
        t = t.replacingOccurrences(of: "'",  with: "")   // U+0027 straight
        t = t.replacingOccurrences(of: "\u{2018}", with: "")  // U+2018 left single quotation mark
        t = t.replacingOccurrences(of: "\u{2019}", with: "")  // U+2019 right single quotation mark
        // Inch marks — stripped without inserting a space (same rule as the apostrophe above)
        // so 7″ / 7" / 7'' / 7′′ all collapse to the same "7" token instead of drifting apart.
        t = t.replacingOccurrences(of: "\u{2033}", with: "")  // ″ double prime
        t = t.replacingOccurrences(of: "\u{2032}", with: "")  // ′ prime
        t = t.replacingOccurrences(of: "\u{201D}", with: "")  // ” right double quotation mark
        t = t.replacingOccurrences(of: #"[_\-\./,'""!?&]+"#, with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespaces)
    }

    /// Strips catalog / release noise from a folder name before token comparison.
    /// Keeps meaningful words (artist, title) and removes: leading year prefixes,
    /// parenthetical/bracketed groups, standalone 3-4 digit numbers (bitrates, years).
    nonisolated static func normalizeFolderName(_ folder: String) -> String {
        var t = folder.lowercased()
        t = t.replacingOccurrences(of: #"^\d{4}\s*[-–]\s*"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\([^\)]*\)"#, with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\[[^\]]*\]"#, with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\b\d{3,4}\b"#, with: " ", options: .regularExpression)
        return normalize(t)
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

    /// Splits a title into (baseTitle, versionDescriptor), WITHOUT pre-normalizing (so brackets survive).
    ///
    /// "Keep On Movin' (Club Mix)"                      → ("keep on movin", "club mix")
    /// "Dirty Cash (Money Talks) (Dime and Dollar mix)"  → ("dirty cash", "dime and dollar mix")
    /// "Jazzie's Groove (Happy Face / Funky Bass)"       → ("jazzies groove", "happy face funky bass")
    /// "Rose Rouge"                                      → ("rose rouge", nil)
    ///
    /// Two-pass strategy:
    ///   Pass 1 — bracket group containing a version keyword (mix, 12", vocal, etc.)
    ///   Pass 2 — any TRAILING parenthetical/bracketed group, even without keywords.
    ///            Catches descriptive subtitles like "(Happy Face / Funky Bass)", "(Piano Groove)"
    ///            that ARE version qualifiers in MusicBrainz but have no mix-keywords.
    nonisolated static func splitVersion(_ title: String) -> (base: String, version: String?) {
        // Lowercase + strip straight apostrophe, but keep brackets INTACT so the regex can see them.
        var t = title.lowercased()
        t = t.replacingOccurrences(of: "'", with: "")

        // Pass 1: bracket group with a version keyword
        let keywordPattern = #"[\(\[]\s*([^\)\]]*?(?:mix|remix|version|edit|dub|instrumental|radio|extended|vocal|7"|12"|rerub|rmx)[^\)\]]*?)\s*[\)\]]"#
        if let matchRange = t.range(of: keywordPattern, options: [.regularExpression, .caseInsensitive]) {
            let versionRaw = String(t[matchRange])
                .trimmingCharacters(in: CharacterSet(charactersIn: "()[] "))
            let withoutVersion = t.replacingCharacters(in: matchRange, with: " ")
            return (normalize(withoutVersion), versionRaw.isEmpty ? nil : normalize(versionRaw))
        }

        // Pass 2: any trailing parenthetical/bracketed group (no nested brackets)
        let trailingPattern = #"[\(\[]\s*([^\(\)\[\]]+?)\s*[\)\]]\s*$"#
        if let matchRange = t.range(of: trailingPattern, options: [.regularExpression, .caseInsensitive]) {
            let versionRaw = String(t[matchRange])
                .trimmingCharacters(in: CharacterSet(charactersIn: "()[] "))
            let withoutVersion = t.replacingCharacters(in: matchRange, with: " ")
            return (normalize(withoutVersion), versionRaw.isEmpty ? nil : normalize(versionRaw))
        }

        return (normalize(title), nil)
    }

    /// Version tokens with filler words removed: "dime and dollar mix" → {dime, dollar}.
    nonisolated static func distinguishingVersionTokens(_ version: String) -> Set<String> {
        Set(version.split(separator: " ").map(String.init).filter { !versionFillerWords.contains($0) })
    }

    /// Version similarity comparing only distinguishing (non-filler) tokens.
    ///
    /// - Both nil → 1.0 (same: no version)
    /// - One nil, one present → 0.5 (uncertain)
    /// - Both present, both reduce to empty after filler strip → 1.0 (both just say "mix")
    /// - Both present, one reduces to empty → 0.5
    /// - Both present with tokens → Jaccard on distinguishing tokens
    nonisolated static func versionSimilarity(_ a: String?, _ b: String?) -> Double {
        switch (a, b) {
        case (nil, nil): return 1.0
        case (nil, _), (_, nil): return 0.5
        case let (.some(va), .some(vb)):
            let tA = distinguishingVersionTokens(va)
            let tB = distinguishingVersionTokens(vb)
            if tA.isEmpty && tB.isEmpty { return 1.0 }
            if tA.isEmpty || tB.isEmpty { return 0.5 }
            return similarity(tokensA: tA, tokensB: tB)
        }
    }
}
