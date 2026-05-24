import Foundation

// MARK: - Shared pool-builder for Mix and Set Builder

enum MixTrackPool {
    /// Tracks with a confident file match and full BPM + Camelot data.
    /// Covers the ~879 Discogs-collection releases.
    static func confident(from tracks: [TrackEntity]) -> [MixTrack] {
        tracks
            .filter {
                $0.fileMatchState == "confident" &&
                $0.effectiveBpm != nil &&
                !($0.effectiveCamelot ?? "").isEmpty
            }
            .map { t in
                MixTrack(
                    displayArtist: t.artistCredit,
                    displayTitle:  t.title,
                    bpm:      t.effectiveBpm!,
                    camelot:  t.effectiveCamelot!,
                    key:      t.effectiveKey ?? "",
                    source:   t.featureSource,
                    filePath: t.primaryLocalFilePath
                )
            }
    }

    /// All locally-analyzed files with a BPM and Camelot key (~13k file pool).
    static func allAnalyzed(from files: [LocalFileEntity]) -> [MixTrack] {
        files
            .filter { !$0.camelot.isEmpty }
            .map { f in
                MixTrack(
                    displayArtist: f.artistFolder.isEmpty ? f.parentFolder : f.artistFolder,
                    displayTitle:  URL(fileURLWithPath: f.filePath)
                        .deletingPathExtension().lastPathComponent,
                    bpm:      f.bpm,
                    camelot:  f.camelot,
                    key:      f.key.isEmpty ? "" : "\(f.key) \(f.scale)",
                    source:   .local,
                    filePath: f.filePath
                )
            }
    }
}
