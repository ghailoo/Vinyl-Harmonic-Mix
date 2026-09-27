import Foundation
import SwiftUI
import AppKit

@Observable
final class DriveMonitor {
    struct FolderState: Identifiable {
        let folder: LibraryFolder
        var isReachable: Bool
        var id: UUID { folder.id }
    }

    private(set) var folders: [FolderState] = []

    /// True when at least one library folder is reachable — the app stays usable on those.
    var isAvailable: Bool { folders.contains { $0.isReachable } }
    var reachableFolders: [LibraryFolder] { folders.filter(\.isReachable).map(\.folder) }
    var missingFolders: [LibraryFolder] { folders.filter { !$0.isReachable }.map(\.folder) }

    private let defaults: UserDefaults
    private var observers: [NSObjectProtocol] = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        refreshAvailability()
        registerObservers()
    }

    deinit {
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
    }

    /// Deep verification, per folder: resolves the bookmark, requires it to still point at the
    /// path the folder's files were indexed under, AND confirms the directory has at least one
    /// non-hidden entry. Stale/ghost mounts return empty or throw — both treated as inaccessible.
    /// Returns ONLY the folders verified reachable right now; gate every destructive
    /// file-system operation on membership in this set, never on "not in the missing list".
    @discardableResult
    func verifyAccessible() -> Set<UUID> {
        let list = LocalLibraryService.folders(defaults: defaults)
        var reachable: Set<UUID> = []
        for folder in list {
            if let url = LocalLibraryService.resolve(folder, defaults: defaults),
               Self.isDeepAccessible(url: url, expectedPath: folder.displayPath) {
                reachable.insert(folder.id)
            }
        }
        folders = list.map { FolderState(folder: $0, isReachable: reachable.contains($0.id)) }
        return reachable
    }

    nonisolated static func isDeepAccessible(url: URL, expectedPath: String) -> Bool {
        // A remount can resolve the bookmark to "/Volumes/Music-1" while rows are stored under
        // "/Volumes/Music"; sweeping then would read every file as missing. Treat as unreachable.
        guard samePath(url.path, expectedPath) else {
            print("[DRIVE-MONITOR] verifyAccessible: bookmark resolved to \(url.path), expected \(expectedPath) — REFUSED")
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

    /// Cheap check for UI state (banner, toolbar enablement). Not a gate for destructive work.
    func refreshAvailability() {
        folders = LocalLibraryService.folders(defaults: defaults).map { folder in
            let reachable = LocalLibraryService.resolve(folder, defaults: defaults).map {
                Self.samePath($0.path, folder.displayPath) && FileManager.default.fileExists(atPath: $0.path)
            } ?? false
            return FolderState(folder: folder, isReachable: reachable)
        }
    }

    nonisolated private static func samePath(_ a: String, _ b: String) -> Bool {
        URL(fileURLWithPath: a).standardizedFileURL.path.lowercased()
            == URL(fileURLWithPath: b).standardizedFileURL.path.lowercased()
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
