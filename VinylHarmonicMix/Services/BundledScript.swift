import Foundation

// Python scripts shipped inside the .app (copied from Scripts/ by the Resources build phase).
// Single lookup for every caller so a missing script fails the same way everywhere.
nonisolated enum BundledScript {
    struct MissingError: LocalizedError {
        let fileName: String
        var errorDescription: String? {
            "\(fileName) is missing from the app bundle — rebuild VinylHarmonicMix so Scripts/\(fileName) is copied into the app."
        }
    }

    /// Absolute path of `fileName` (e.g. "essentia_cue.py") inside the app bundle.
    static func path(_ fileName: String) throws -> String {
        let url = URL(fileURLWithPath: fileName)
        guard let found = Bundle.main.url(forResource: url.deletingPathExtension().lastPathComponent,
                                          withExtension: url.pathExtension) else {
            throw MissingError(fileName: fileName)
        }
        return found.path
    }
}
