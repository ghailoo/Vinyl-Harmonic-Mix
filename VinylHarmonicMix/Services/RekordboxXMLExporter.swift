import Foundation
import CryptoKit
import SwiftData

/// Generates Rekordbox-compatible XML library files from VinylHarmonicMix data.
/// Pure data transformation — no UI, no SwiftData mutation.
/// Output XML can be imported in Rekordbox via Preferences → Advanced → Database → Imported Library.
struct RekordboxXMLExporter {
    let tracks: [TrackEntity]
    let setlists: [SetlistEntity]

    // MARK: - Public API

    func generate() -> String {
        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <DJ_PLAYLISTS Version="1.0.0">
          <PRODUCT Name="VinylHarmonicMix" Version="2.1" Company="ghailoo"/>
          <COLLECTION Entries="\(tracks.count)">
        """

        for track in tracks {
            let rendered = renderTrack(track)
            if !rendered.isEmpty { xml += "\n" + rendered }
        }

        xml += "\n  </COLLECTION>\n"
        xml += renderPlaylists()
        xml += "\n</DJ_PLAYLISTS>\n"
        return xml
    }

    // MARK: - TRACK

    private func renderTrack(_ track: TrackEntity) -> String {
        guard let filePath = track.primaryLocalFilePath else { return "" }

        let trackID = stableTrackID(for: filePath)
        let localFile = track.localFiles.first(where: { $0.filePath == filePath })

        let kind       = formatKind(from: localFile?.format ?? "")
        let size       = localFile?.fileSizeBytes ?? 0
        let totalTime  = (localFile?.durationMs ?? track.durationMs ?? 0) / 1000

        let basicInfo  = track.collectionItem?.basicInformation
        let album      = basicInfo?.title ?? ""
        let genre      = basicInfo?.genres.first ?? ""
        let label      = basicInfo?.labels.first?.name ?? ""
        let year       = basicInfo?.year ?? 0

        let bpm        = track.effectiveBpm ?? 0
        let tonality   = resolveTonality(track: track)
        let dateAdded  = sanitiseDate(track.collectionItem?.dateAdded ?? "")
        let rating     = ratingScale(from: track.collectionItem?.rating ?? 0)
        let location   = locationURL(from: filePath)

        var t = """
            <TRACK TrackID="\(trackID)"
              Name="\(esc(track.title))"
              Artist="\(esc(track.artistCredit))"
              Composer=""
              Album="\(esc(album))"
              Grouping=""
              Genre="\(esc(genre))"
              Kind="\(esc(kind))"
              Size="\(size)"
              TotalTime="\(totalTime)"
              DiscNumber="0"
              TrackNumber="0"
              Year="\(year)"
              AverageBpm="\(formatBPM(bpm))"
              DateAdded="\(dateAdded)"
              BitRate="0"
              SampleRate="44100"
              Comments=""
              PlayCount="0"
              Rating="\(rating)"
              Location="\(location)"
              Remixer=""
              Tonality="\(esc(tonality))"
              Label="\(esc(label))"
              Mix="">
        """

        if bpm > 0 {
            t += "\n      <TEMPO Inizio=\"0.000\" Bpm=\"\(formatBPM(bpm))\" Metro=\"4/4\" Battito=\"1\"/>"
        }

        // Cue points live on LocalFileEntity, not TrackEntity.
        let cues = (localFile?.cuePoints ?? []).sorted { $0.timeSec < $1.timeSec }
        for cue in cues {
            // CuePointEntity has no label field; use energyDirection if non-empty.
            let cueName = cue.energyDirection.isEmpty ? "" : cue.energyDirection
            t += "\n      <POSITION_MARK Name=\"\(esc(cueName))\" Type=\"0\" Start=\"\(formatTime(cue.timeSec))\" Num=\"-1\"/>"
        }

        t += "\n    </TRACK>"
        return t
    }

    // MARK: - PLAYLISTS

    private func renderPlaylists() -> String {
        var xml = "  <PLAYLISTS>\n"
        xml += "    <NODE Type=\"0\" Name=\"ROOT\" Count=\"\(setlists.count)\">\n"

        for setlist in setlists {
            let items = setlist.items
                .sorted { $0.position < $1.position }
                .filter { !$0.filePath.isEmpty }
            xml += "      <NODE Name=\"\(esc(setlist.name))\" Type=\"1\" KeyType=\"0\" Entries=\"\(items.count)\">\n"
            for item in items {
                xml += "        <TRACK Key=\"\(stableTrackID(for: item.filePath))\"/>\n"
            }
            xml += "      </NODE>\n"
        }

        xml += "    </NODE>\n"
        xml += "  </PLAYLISTS>"
        return xml
    }

    // MARK: - Helpers

    private func stableTrackID(for filePath: String) -> Int32 {
        let hash = SHA256.hash(data: Data(filePath.utf8))
        let bytes = Array(hash)
        let u32 = UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16
                | UInt32(bytes[2]) << 8  | UInt32(bytes[3])
        return Int32(bitPattern: u32 & 0x7FFFFFFF)
    }

    private func formatKind(from ext: String) -> String {
        switch ext.lowercased() {
        case "mp3":         return "MP3 File"
        case "flac":        return "FLAC File"
        case "m4a", "mp4":  return "M4A File"
        case "wav":         return "WAV File"
        case "aif", "aiff": return "AIFF File"
        default:            return ""
        }
    }

    /// Converts a key string to Rekordbox musical notation.
    /// Handles two input formats:
    ///   "A minor"  → "Am"    (from TrackEntity.effectiveKey)
    ///   "8A"       → "Am"    (Camelot fallback from effectiveCamelot)
    private func musicalNotation(from key: String) -> String {
        let trimmed = key.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "" }

        // "A minor" / "F# major" format from effectiveKey
        let parts = trimmed.split(separator: " ", maxSplits: 1)
        if parts.count == 2 {
            let note  = String(parts[0])
            let scale = String(parts[1]).lowercased()
            if scale == "minor" { return "\(note)m" }
            if scale == "major" { return note }
        }

        // Camelot fallback
        let camelotMap: [String: String] = [
            "1A": "Abm", "2A": "Ebm", "3A": "Bbm", "4A":  "Fm", "5A": "Cm",  "6A": "Gm",
            "7A":  "Dm", "8A":  "Am", "9A":  "Em", "10A": "Bm", "11A": "F#m", "12A": "Dbm",
            "1B":   "B", "2B":  "F#", "3B":  "Db", "4B": "Ab", "5B": "Eb",   "6B": "Bb",
            "7B":   "F", "8B":   "C", "9B":   "G", "10B": "D", "11B":  "A",  "12B":  "E"
        ]
        return camelotMap[trimmed] ?? trimmed
    }

    private func resolveTonality(track: TrackEntity) -> String {
        if let k = track.effectiveKey, !k.isEmpty {
            return musicalNotation(from: k)
        }
        if let c = track.effectiveCamelot, !c.isEmpty {
            return musicalNotation(from: c)
        }
        return ""
    }

    private func ratingScale(from discogsRating: Int) -> Int {
        max(0, min(5, discogsRating)) * 51
    }

    /// dateAdded on CollectionItemEntity is already a string from Discogs (e.g. "2023-04-15").
    /// Just validate the format; fall back to today if malformed.
    private func sanitiseDate(_ raw: String) -> String {
        let iso = DateFormatter()
        iso.dateFormat = "yyyy-MM-dd"
        iso.locale = Locale(identifier: "en_US_POSIX")
        iso.timeZone = TimeZone(identifier: "UTC")
        if iso.date(from: raw) != nil { return raw }
        return iso.string(from: Date())
    }

    private func formatBPM(_ bpm: Double) -> String { String(format: "%.2f", bpm) }
    private func formatTime(_ s: Double)  -> String { String(format: "%.3f", s) }

    private func locationURL(from path: String) -> String {
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        return "file://localhost" + encoded
    }

    private func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&",  with: "&amp;")
         .replacingOccurrences(of: "<",  with: "&lt;")
         .replacingOccurrences(of: ">",  with: "&gt;")
         .replacingOccurrences(of: "\"", with: "&quot;")
         .replacingOccurrences(of: "'",  with: "&apos;")
    }
}
