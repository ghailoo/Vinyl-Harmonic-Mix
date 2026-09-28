import SwiftData
import Foundation

@Model
final class SetlistEntity {
    @Attribute(.unique) var id: String
    var name: String
    var createdAt: Date
    var notes: String
    @Relationship(deleteRule: .cascade, inverse: \SetlistItemEntity.setlist)
    var items: [SetlistItemEntity] = []

    init(name: String = "Untitled Set") {
        self.id = UUID().uuidString
        self.name = name
        self.createdAt = .now
        self.notes = ""
    }
}

// MARK: - Undo (Sets page B1/B2)
//
// Deleting a set or removing a track registers with the window's UndoManager, so ⌘Z
// (Edit ▸ Undo) restores it and ⇧⌘Z redoes. Snapshots are plain values and restore by
// looking the set up by its stable `id`, never by holding the deleted @Model object —
// so a track removal can still be undone after its set was deleted and restored.
// Scope: the window's UndoManager, i.e. until the window closes or the app quits.

struct SetlistItemSnapshot {
    let position: Int, filePath: String, displayArtist: String, displayTitle: String
    let bpm: Double, camelot: String, key: String, addedAt: Date

    init(_ item: SetlistItemEntity) {
        position = item.position; filePath = item.filePath
        displayArtist = item.displayArtist; displayTitle = item.displayTitle
        bpm = item.bpm; camelot = item.camelot; key = item.key; addedAt = item.addedAt
    }

    func makeEntity(position: Int) -> SetlistItemEntity {
        let item = SetlistItemEntity(position: position, filePath: filePath, displayArtist: displayArtist,
                                     displayTitle: displayTitle, bpm: bpm, camelot: camelot, key: key)
        item.addedAt = addedAt
        return item
    }
}

@MainActor
enum SetlistUndo {
    static func set(id: String, in context: ModelContext) -> SetlistEntity? {
        var fd = FetchDescriptor<SetlistEntity>(predicate: #Predicate { $0.id == id })
        fd.fetchLimit = 1
        return try? context.fetch(fd).first
    }

    /// Deletes `set` and registers ⌘Z. Returns the token so a toast's Undo button can
    /// call `restore` directly (and drop the now-stale ⌘Z entry) without touching whatever
    /// else is on top of the undo stack.
    @discardableResult
    static func deleteSet(_ set: SetlistEntity, context: ModelContext,
                          undoManager: UndoManager?) -> DeletedSet {
        let token = DeletedSet(set)
        context.delete(set)
        try? context.save()
        // Closures capture `token` strongly — UndoManager doesn't retain its targets.
        undoManager?.registerUndo(withTarget: token) { _ in
            token.restore(context: context, undoManager: undoManager)
        }
        undoManager?.setActionName("Delete Set")
        return token
    }

    /// Removes `item` from its set (renumbering the rest) and registers ⌘Z to put it back
    /// at its original position.
    static func removeItem(_ item: SetlistItemEntity, from set: SetlistEntity,
                           context: ModelContext, undoManager: UndoManager?) {
        let setID = set.id
        let snapshot = SetlistItemSnapshot(item)
        let originalIndex = set.items.sorted { $0.position < $1.position }
            .firstIndex { $0.persistentModelID == item.persistentModelID } ?? snapshot.position
        let remaining = set.items.filter { $0.persistentModelID != item.persistentModelID }
            .sorted { $0.position < $1.position }
        context.delete(item)
        for (newPos, track) in remaining.enumerated() { track.position = newPos }
        try? context.save()

        undoManager?.registerUndo(withTarget: context) { context in
            guard let set = SetlistUndo.set(id: setID, in: context) else { return }
            var ordered = set.items.sorted { $0.position < $1.position }
            let restored = snapshot.makeEntity(position: 0)
            context.insert(restored)
            set.items.append(restored)
            ordered.insert(restored, at: min(originalIndex, ordered.count))
            for (newPos, track) in ordered.enumerated() { track.position = newPos }
            try? context.save()
            undoManager?.registerUndo(withTarget: context) { context in
                guard let set = SetlistUndo.set(id: setID, in: context),
                      let item = set.items.first(where: {
                          $0.filePath == snapshot.filePath && $0.addedAt == snapshot.addedAt
                      }) else { return }
                removeItem(item, from: set, context: context, undoManager: undoManager)
            }
            undoManager?.setActionName("Remove Track")
        }
        undoManager?.setActionName("Remove Track")
    }
}

/// Value snapshot of a deleted set; restores under the same `id` so later undo entries
/// that look the set up by id (track removals) still resolve.
@MainActor
final class DeletedSet {
    let id: String, name: String, createdAt: Date, notes: String
    let items: [SetlistItemSnapshot]

    init(_ set: SetlistEntity) {
        id = set.id; name = set.name; createdAt = set.createdAt; notes = set.notes
        items = set.items.map(SetlistItemSnapshot.init).sorted { $0.position < $1.position }
    }

    @discardableResult
    func restore(context: ModelContext, undoManager: UndoManager?) -> SetlistEntity {
        let set = SetlistEntity(name: name)
        set.id = id
        set.createdAt = createdAt
        set.notes = notes
        context.insert(set)
        for snap in items {
            let item = snap.makeEntity(position: snap.position)
            context.insert(item)
            set.items.append(item)
        }
        try? context.save()
        // Redo re-snapshots via deleteSet: tracks added since the restore aren't lost.
        undoManager?.registerUndo(withTarget: self) { [self] _ in
            guard let set = SetlistUndo.set(id: id, in: context) else { return }
            SetlistUndo.deleteSet(set, context: context, undoManager: undoManager)
        }
        undoManager?.setActionName("Delete Set")
        return set
    }
}
