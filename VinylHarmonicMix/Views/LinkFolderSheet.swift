import SwiftUI

/// "Link folder…" confirmation: one row per release track, track ↔ proposed file side by side in
/// the File Matches compareLine style. Every row can be re-pointed or excluded. Nothing is written
/// here — `onLink` gets the confirmed pairs, and replacing an existing link asks first.
struct LinkFolderSheet: View {

    struct Owner {
        let trackMBID: String
        let label: String          // "Artist – Title" of the track the file is confirmed for now
    }

    struct Row: Identifiable {
        let id: String             // trackMBID — MusicBrainz or surrogate "discogs:…"
        let position: String
        let trackLine: String      // "Artist – Title"
        let currentPath: String?   // existing confirmed link, if any
        var filePath: String?
        var included: Bool
        var note: String           // why this file was proposed
    }

    struct Proposal: Identifiable {
        let id = UUID()
        let folder: URL
        let inLibrary: Bool
        let files: [String]              // every audio path read from the folder
        let owners: [String: Owner]      // path → track it is confirmed for today
        let rows: [Row]
    }

    let proposal: Proposal
    let onLink: ([(trackMBID: String, url: URL)]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var rows: [Row]
    @State private var confirmReplace = false

    init(proposal: Proposal, onLink: @escaping ([(trackMBID: String, url: URL)]) -> Void) {
        self.proposal = proposal
        self.onLink = onLink
        _rows = State(initialValue: proposal.rows)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Link folder").font(.title3.weight(.semibold))
                Text(proposal.folder.path)
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                    .textSelection(.enabled)
                if !proposal.inLibrary {
                    Label("This folder is outside your library folders, so future library scans won't cover it. "
                          + "The links made here still work.", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            .padding()
            Divider()

            List {
                ForEach($rows) { $row in rowView($row) }
            }

            Divider()
            HStack(spacing: 8) {
                if let problem {
                    Text(problem).font(.caption).foregroundStyle(.red)
                } else {
                    Text("\(toLink.count) of \(rows.count) tracks will be linked")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Link \(toLink.count)") {
                    if replacements.isEmpty { apply() } else { confirmReplace = true }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(toLink.isEmpty || problem != nil)
            }
            .padding()
        }
        .frame(minWidth: 780, idealWidth: 860, minHeight: 460, idealHeight: 560)
        .alert("Replace existing links?", isPresented: $confirmReplace) {
            Button("Cancel", role: .cancel) { }
            Button("Replace", role: .destructive) { apply() }
        } message: {
            Text(replacements.joined(separator: "\n"))
        }
    }

    @ViewBuilder
    private func rowView(_ row: Binding<Row>) -> some View {
        let r = row.wrappedValue
        HStack(alignment: .top, spacing: 10) {
            Toggle("", isOn: row.included)
                .labelsHidden()
                .disabled(r.filePath == nil)
                .help(r.included ? "Exclude this track" : "Include this track")
                .accessibilityLabel("Link \(r.position) \(r.trackLine)")
            Text(r.position)
                .font(.body.monospaced()).foregroundStyle(.secondary)
                .frame(width: 40, alignment: .leading)
            compareLine(icon: "opticaldisc", original: r.trackLine)
                .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    compareLine(icon: "doc", original: r.filePath.map(displayName) ?? "No file")
                        .foregroundStyle(r.filePath == nil ? .tertiary : .primary)
                    Spacer(minLength: 4)
                    Menu("Change") {
                        Button("No file") {
                            row.filePath.wrappedValue = nil
                            row.included.wrappedValue = false
                        }
                        Divider()
                        ForEach(proposal.files, id: \.self) { path in
                            Button(displayName(path)) {
                                row.filePath.wrappedValue = path
                                row.included.wrappedValue = true
                                row.note.wrappedValue = "chosen by you"
                            }
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .controlSize(.small)
                    .fixedSize()
                }
                rowCaptions(r)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 4)
        .opacity(r.included || r.filePath == nil ? 1 : 0.6)
    }

    @ViewBuilder
    private func rowCaptions(_ r: Row) -> some View {
        Text(r.note).font(.caption2).foregroundStyle(.secondary)
        if let current = r.currentPath {
            if current == r.filePath {
                Text("Already linked to this file").font(.caption2).foregroundStyle(.secondary)
            } else {
                Text("Replaces current link: \(URL(fileURLWithPath: current).lastPathComponent)")
                    .font(.caption2).foregroundStyle(.orange)
            }
        }
        if let path = r.filePath, let owner = proposal.owners[path], owner.trackMBID != r.id {
            Text("File is currently linked to \(owner.label)").font(.caption2).foregroundStyle(.orange)
        }
    }

    // MARK: - Derived

    /// Included rows that would actually change something.
    private var toLink: [Row] {
        rows.filter { $0.included && $0.filePath != nil && $0.filePath != $0.currentPath }
    }

    private var problem: String? {
        let paths = toLink.compactMap(\.filePath)
        return Set(paths).count == paths.count ? nil : "The same file is chosen for more than one track."
    }

    /// Existing confirmed links that applying would overwrite — asked about before writing.
    private var replacements: [String] {
        toLink.flatMap { r -> [String] in
            var out: [String] = []
            if let current = r.currentPath {
                out.append("\(r.position): replaces \(URL(fileURLWithPath: current).lastPathComponent)")
            }
            if let path = r.filePath, let owner = proposal.owners[path], owner.trackMBID != r.id {
                out.append("\(displayName(path)): taken from \(owner.label)")
            }
            return out
        }
    }

    /// Path relative to the picked folder (keeps "CD1/01 …" vs "CD2/01 …" apart), else the file name.
    private func displayName(_ path: String) -> String {
        let root = proposal.folder.path.hasSuffix("/") ? proposal.folder.path : proposal.folder.path + "/"
        return path.hasPrefix(root) ? String(path.dropFirst(root.count)) : URL(fileURLWithPath: path).lastPathComponent
    }

    private func apply() {
        onLink(toLink.compactMap { r in r.filePath.map { (trackMBID: r.id, url: URL(fileURLWithPath: $0)) } })
        dismiss()
    }
}
