import SwiftUI

struct CollectionGridView: View {
    @Environment(CollectionViewModel.self) private var viewModel
    @Environment(MBIDScanCoordinator.self) private var scanCoordinator
    @State private var searchQuery = ""
    @State private var selectedItem: CollectionItem?
    @State private var showRescanAlert = false

    private let columns = [GridItem(.adaptive(minimum: 160, maximum: 200), spacing: 16)]

    var body: some View {
        VStack(spacing: 0) {
            if scanCoordinator.showBanner {
                MBIDScanBanner()
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            if viewModel.items.isEmpty {
                emptyState
            } else {
                gridContent
                    .sheet(item: $selectedItem) { item in
                        CollectionDetailView(item: item)
                    }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: scanCoordinator.showBanner)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                TextField("Search artist, title, year…", text: $searchQuery)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 240)
                scanButton
                Button {
                    Task { await viewModel.importCollection() }
                } label: {
                    Label("Re-import from Discogs", systemImage: "arrow.down.circle")
                }
                .help("Re-import from Discogs")
            }
        }
        .alert("Rescan All Releases?", isPresented: $showRescanAlert) {
            Button("Rescan", role: .destructive) { scanCoordinator.startRescan() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will clear all existing MusicBrainz matches and re-scan every release.")
        }
    }

    private var scanButton: some View {
        let unscanned = scanCoordinator.unscannedCount
        let notFound = scanCoordinator.notFoundCount
        let isActive: Bool = {
            switch scanCoordinator.phase {
            case .scanning, .paused: return true
            default: return false
            }
        }()
        let badgeCount = unscanned > 0 ? unscanned : notFound

        return Menu {
            Button {
                scanCoordinator.start()
            } label: {
                Label("Scan unscanned (\(unscanned))", systemImage: "magnifyingglass")
            }
            .disabled(unscanned == 0 || isActive)

            Button {
                print("🔘 [1] Retry notFound menu item tapped")
                print("🔘 [1a] Current notFoundCount = \(scanCoordinator.notFoundCount)")
                print("🔘 [1b] Current phase = \(scanCoordinator.phase)")
                scanCoordinator.startSearchScan()
                print("🔘 [1c] After calling startSearchScan(), phase = \(scanCoordinator.phase)")
            } label: {
                Label("Retry notFound (\(notFound))", systemImage: "arrow.clockwise.circle")
            }
            .disabled(notFound == 0 || isActive)

            Divider()

            Button(role: .destructive) {
                showRescanAlert = true
            } label: {
                Label("Rescan everything…", systemImage: "arrow.counterclockwise")
            }
            .disabled(isActive)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "music.note.list")
                if badgeCount > 0 {
                    Text("\(badgeCount)")
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.2))
                        .cornerRadius(4)
                }
            }
        }
        .help("Scan MusicBrainz IDs")
    }

    private var gridContent: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 20) {
                ForEach(filteredItems) { item in
                    Button { selectedItem = item } label: {
                        CollectionCardView(item: item)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var filteredItems: [CollectionItem] {
        guard !searchQuery.isEmpty else { return viewModel.items }
        let q = searchQuery.lowercased()
        return viewModel.items.filter { item in
            item.basicInformation.title.lowercased().contains(q) ||
            item.basicInformation.artists.map(\.name).joined(separator: " & ").lowercased().contains(q) ||
            String(item.basicInformation.year).contains(q)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 24) {
            Spacer()
            switch viewModel.phase {
            case .idle, .loaded:
                Image(systemName: "record.circle")
                    .font(.system(size: 64))
                    .foregroundStyle(.secondary)
                Text("Your vinyl collection will appear here.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button {
                    Task { await viewModel.importCollection() }
                } label: {
                    Label("Import Collection", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!viewModel.isConfigured)
            case .loading(let progress):
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 300)
                Text(progressLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                Button {
                    Task { await viewModel.importCollection() }
                } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!viewModel.isConfigured)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var progressLabel: String {
        guard viewModel.totalPages > 0 else { return "Starting import…" }
        return "Importing page \(viewModel.currentPage) of \(viewModel.totalPages)"
    }
}
