import Foundation
import os

// ponytail: temporary instrumentation for the Sep 2026 sidebar-switch perf investigation.
// Prints elapsed milliseconds to the Xcode console (grep "[Perf]"). Remove once Step 3's
// "after" measurements confirm the fix and this file is no longer needed.
enum PerfLog {
    private static let logger = Logger(subsystem: "com.vinylharmonicmix.perf", category: "sidebar-switch")
    private static var starts: [String: UInt64] = [:]

    static func begin(_ label: String) {
        starts[label] = DispatchTime.now().uptimeNanoseconds
    }

    @discardableResult
    static func end(_ label: String) -> Double {
        guard let start = starts.removeValue(forKey: label) else { return 0 }
        let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        logger.info("[Perf] \(label, privacy: .public): \(ms, format: .fixed(precision: 2), privacy: .public) ms")
        print(String(format: "[Perf] %@: %.2f ms", label, ms))
        return ms
    }

    /// For one-shot sync timings without a matching begin/end pair.
    static func measure<T>(_ label: String, _ block: () -> T) -> T {
        let start = DispatchTime.now().uptimeNanoseconds
        let result = block()
        let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        logger.info("[Perf] \(label, privacy: .public): \(ms, format: .fixed(precision: 2), privacy: .public) ms")
        print(String(format: "[Perf] %@: %.2f ms", label, ms))
        return result
    }
}
