import Foundation

// MARK: - filePath → release thumbnail URL lookup

enum MixCoverArt {
    /// Build a [filePath: thumbURL] map by walking TrackEntity rows.
    ///
    /// Chain: primaryLocalFilePath → collectionItem → basicInformation.thumb
    ///
    /// Only entries with a non-empty thumb URL are included.
    /// File-level-only tracks (no collectionItem) are silently skipped —
    /// callers should fall back to a placeholder for those keys.
    static func thumbURLs(from tracks: [TrackEntity]) -> [String: URL] {
        var result: [String: URL] = [:]
        result.reserveCapacity(tracks.count)
        for track in tracks {
            guard let fp = track.primaryLocalFilePath, !fp.isEmpty,
                  let thumbStr = track.collectionItem?.basicInformation?.thumb,
                  !thumbStr.isEmpty,
                  let url = URL(string: thumbStr) else { continue }
            result[fp] = url
        }
        return result
    }
}
