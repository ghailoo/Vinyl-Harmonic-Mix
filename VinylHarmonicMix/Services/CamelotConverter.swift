import Foundation

enum CamelotConverter {

    static func camelotCode(forNote note: String?, scale: String?) -> String? {
        guard let note, let scale else { return nil }
        let normalized = normalizeNote(note)
        let isMinor = scale.lowercased() == "minor"

        let majorMap: [String: String] = [
            "C": "8B", "G": "9B", "D": "10B", "A": "11B", "E": "12B",
            "B": "1B", "F#": "2B", "C#": "3B", "G#": "4B",
            "D#": "5B", "A#": "6B", "F": "7B"
        ]
        let minorMap: [String: String] = [
            "A": "8A", "E": "9A", "B": "10A", "F#": "11A", "C#": "12A",
            "G#": "1A", "D#": "2A", "A#": "3A",
            "F": "4A", "C": "5A", "G": "6A", "D": "7A"
        ]
        return isMinor ? minorMap[normalized] : majorMap[normalized]
    }

    // Friendly description for display: "8A" → "Am", "8B" → "C"
    static let descriptions: [String: String] = [
        "1A": "Abm", "1B": "B",
        "2A": "Ebm", "2B": "F#",
        "3A": "Bbm", "3B": "Db",
        "4A": "Fm",  "4B": "Ab",
        "5A": "Cm",  "5B": "Eb",
        "6A": "Gm",  "6B": "Bb",
        "7A": "Dm",  "7B": "F",
        "8A": "Am",  "8B": "C",
        "9A": "Em",  "9B": "G",
        "10A": "Bm", "10B": "D",
        "11A": "F#m", "11B": "A",
        "12A": "C#m", "12B": "E"
    ]

    static func compatibleCodes(for code: String) -> [String] {
        guard let number = Int(code.dropLast()), let letter = code.last else { return [] }
        let otherLetter: Character = (letter == "A") ? "B" : "A"
        let next = (number % 12) + 1
        let prev = ((number - 2 + 12) % 12) + 1
        return [
            "\(number)\(otherLetter)",
            "\(next)\(letter)",
            "\(prev)\(letter)"
        ]
    }

    private static func normalizeNote(_ note: String) -> String {
        let map: [String: String] = [
            "Db": "C#", "Eb": "D#", "Gb": "F#", "Ab": "G#", "Bb": "A#"
        ]
        return map[note] ?? note
    }
}
