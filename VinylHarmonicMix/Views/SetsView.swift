import SwiftUI
import SwiftData

struct SetsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.undoManager) private var undoManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Query(sort: \SetlistEntity.createdAt, order: .reverse) private var sets: [SetlistEntity]

    @State private var selectedSet: SetlistEntity?
    @State private var deletedSet: DeletedSet?   // drives the "Set deleted — Undo" toast
    @State private var renamingSet: SetlistEntity?
    @State private var renameText = ""
    @AppStorage("setsListWidth") private var listWidth: Double = 240

    // Plain HSplitView (not a nested NavigationSplitView) so the page fills ContentView's
    // detail pane like the other sections instead of adding a third column + toolbar.
    var body: some View {
        HSplitView {
            listPanel
                .frame(minWidth: 200, idealWidth: listWidth, maxWidth: 420)
                .background(listWidthObserver)
            detailPanel
                .frame(minWidth: 360)
                .layoutPriority(1)
        }
        .overlay(alignment: .bottom) {
            if let deleted = deletedSet {
                HStack(spacing: 10) {
                    Text("“\(deleted.name)” deleted")
                        .font(.caption.weight(.medium))
                    Button("Undo") { undoDelete(deleted) }
                        .buttonStyle(.link)
                        .font(.caption.weight(.semibold))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.thinMaterial, in: Capsule())
                .padding(.bottom, 12)
                .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : .snappy, value: deletedSet?.id)
    }

    // ponytail: HSplitView has no divider binding — same live-width observer trick as FileMatchesView.
    private var listWidthObserver: some View {
        GeometryReader { geo in
            Color.clear.onChange(of: geo.size.width) { _, w in
                if w > 0 { listWidth = w }
            }
        }
    }

    private var listHeader: some View {
        HStack {
            Text("Sets")
                .font(.headline)
            Spacer()
            Button(action: createNewSet) {
                Label("New Set", systemImage: "plus")
            }
            .buttonStyle(.borderless)
            .help("Create new set")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - List panel

    private var listPanel: some View {
        VStack(spacing: 0) {
            listHeader
            Divider()
            if sets.isEmpty {
                emptyState
            } else {
                List(selection: $selectedSet) {
                    ForEach(sets) { setlist in
                        SetlistRowView(
                            setlist: setlist,
                            onRename: { startRename(setlist) },
                            onDelete: { deleteSet(setlist) }
                        )
                        .tag(setlist)
                    }
                }
                .listStyle(.sidebar)
            }
        }
        .sheet(isPresented: Binding(
            get: { renamingSet != nil },
            set: { if !$0 { renamingSet = nil } }
        )) {
            RenameSetSheet(text: $renameText) {
                commitRename()
            } onCancel: {
                renamingSet = nil
            }
        }
    }

    // MARK: - Detail panel

    @ViewBuilder
    private var detailPanel: some View {
        if let set = selectedSet {
            SetLibraryView(setlist: set)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "list.bullet.rectangle")
                    .font(.iconHero)
                    .foregroundStyle(.tertiary)
                Text("Select a set")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "list.bullet.rectangle")
                .font(.iconHero)
                .foregroundStyle(.tertiary)
            Text("No Sets Yet")
                .font(.title3.bold())
            Text("Create a set to organise tracks for a mix.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Button(action: createNewSet) {
                Label("New Set", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Actions

    private func createNewSet() {
        let set = SetlistEntity()
        modelContext.insert(set)
        try? modelContext.save()
        selectedSet = set
        startRename(set)
    }

    private func startRename(_ set: SetlistEntity) {
        renamingSet = set
        renameText = set.name
    }

    private func commitRename() {
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            renamingSet?.name = trimmed
            try? modelContext.save()
        }
        renamingSet = nil
    }

    // No confirmation: single-set delete is undoable (⌘Z or the toast). Add a dialog only
    // if multi-selection delete ever lands.
    private func deleteSet(_ set: SetlistEntity) {
        if selectedSet == set { selectedSet = nil }
        let token = SetlistUndo.deleteSet(set, context: modelContext, undoManager: undoManager)
        deletedSet = token
        Task {
            try? await Task.sleep(for: .seconds(5))
            if deletedSet === token { deletedSet = nil }
        }
    }

    private func undoDelete(_ token: DeletedSet) {
        undoManager?.removeAllActions(withTarget: token)   // ⌘Z would otherwise restore it twice
        selectedSet = token.restore(context: modelContext, undoManager: nil)
        deletedSet = nil
    }
}

// MARK: - Row

private struct SetlistRowView: View {
    let setlist: SetlistEntity
    let onRename: () -> Void
    let onDelete: () -> Void

    private var itemCount: Int { setlist.items.count }
    private var subtitle: String {
        let count = itemCount
        let countStr = count == 1 ? "1 track" : "\(count) tracks"
        let date = setlist.createdAt.formatted(date: .abbreviated, time: .omitted)
        return "\(countStr) · \(date)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(setlist.name)
                .font(.body.weight(.medium))
                .lineLimit(1)
            Text(subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button("Rename…", action: onRename)
            Divider()
            Button("Delete", role: .destructive, action: onDelete)
        }
    }
}

// MARK: - Rename sheet

private struct RenameSetSheet: View {
    @Binding var text: String
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Text("Rename Set")
                .font(.headline)
            TextField("Set name", text: $text)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 260)
                .onSubmit { onConfirm() }
            HStack {
                Button("Cancel", role: .cancel, action: onCancel)
                Spacer()
                Button("Rename") { onConfirm() }
                    .buttonStyle(.borderedProminent)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(minWidth: 320)
    }
}
