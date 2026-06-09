import Foundation
import SwiftUI
import AppKit

@Observable
final class DriveMonitor {
    var isAvailable: Bool = false
    var libraryURL: URL? = nil
    var displayPath: String = ""

    private var observers: [NSObjectProtocol] = []

    init() {
        displayPath = UserDefaults.standard.string(forKey: LocalLibraryService.displayPathKey) ?? ""
        refreshAvailability()
        registerObservers()
    }

    deinit {
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
    }

    /// Deep verification: resolves bookmark AND confirms the directory has at least one
    /// non-hidden entry. Stale/ghost mounts return empty or throw — both treated as inaccessible.
    /// Use this gate before any destructive file-system operation.
    func verifyAccessible() -> Bool {
        guard let url = LocalLibraryService.resolveLibraryBookmark() else {
            print("[DRIVE-MONITOR] verifyAccessible: bookmark nil")
            return false
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            print("[DRIVE-MONITOR] verifyAccessible: fileExists false at \(url.path)")
            return false
        }
        do {
            let contents = try FileManager.default.contentsOfDirectory(atPath: url.path)
            let nonHiddenCount = contents.filter { !$0.hasPrefix(".") }.count
            print("[DRIVE-MONITOR] verifyAccessible: \(nonHiddenCount) non-hidden entries at \(url.path)")
            if nonHiddenCount < 1 {
                print("[DRIVE-MONITOR] verifyAccessible: REFUSED — directory appears empty (possibly stale mount)")
                return false
            }
            return true
        } catch {
            print("[DRIVE-MONITOR] verifyAccessible: contentsOfDirectory failed: \(error)")
            return false
        }
    }

    func refreshAvailability() {
        displayPath = UserDefaults.standard.string(forKey: LocalLibraryService.displayPathKey) ?? ""
        guard let url = LocalLibraryService.resolveLibraryBookmark() else {
            isAvailable = false
            libraryURL = nil
            return
        }
        libraryURL = url
        isAvailable = FileManager.default.fileExists(atPath: url.path)
    }

    private func registerObservers() {
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification,
                     NSWorkspace.didUnmountNotification] {
            let token = nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.refreshAvailability()
            }
            observers.append(token)
        }
    }
}
