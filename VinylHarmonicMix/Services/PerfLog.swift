import Foundation
import os

// ponytail: temporary instrumentation for the Sep 2026 sidebar-switch perf investigation.
// Logged at .notice so runs persist in the unified log — read them back with:
//   log show --last 30m --style compact --predicate 'subsystem == "com.vinylharmonicmix.perf"'
// Remove once Step 3's "after" measurements confirm the fix and this file is no longer needed.
enum PerfLog {
    private static let logger = Logger(subsystem: "com.vinylharmonicmix.perf", category: "sidebar-switch")
    private static var starts: [String: UInt64] = [:]
    private static var pendingSwitch: (page: String, start: UInt64)?

    static func begin(_ label: String) {
        starts[label] = DispatchTime.now().uptimeNanoseconds
    }

    @discardableResult
    static func end(_ label: String) -> Double {
        guard let start = starts.removeValue(forKey: label) else { return 0 }
        return log(label, since: start)
    }

    /// For one-shot sync timings without a matching begin/end pair.
    static func measure<T>(_ label: String, _ block: () -> T) -> T {
        let start = DispatchTime.now().uptimeNanoseconds
        let result = block()
        log(label, since: start)
        return result
    }

    /// Sidebar click → page onAppear (body + first layout), then → next main-queue turn.
    static func beginSwitch(to page: String) {
        logger.notice("[Perf] ---- switch → \(page, privacy: .public) ----")
        pendingSwitch = (page, DispatchTime.now().uptimeNanoseconds)
    }

    static func pageAppeared(_ page: String) {
        guard let pending = pendingSwitch, pending.page == page else { return }
        pendingSwitch = nil
        log("switch→\(page) click→onAppear", since: pending.start)
        DispatchQueue.main.async { log("switch→\(page) click→next runloop", since: pending.start) }
    }

    @discardableResult
    private static func log(_ label: String, since start: UInt64) -> Double {
        let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        logger.notice("[Perf] \(label, privacy: .public): \(ms, format: .fixed(precision: 2), privacy: .public) ms")
        return ms
    }
}
