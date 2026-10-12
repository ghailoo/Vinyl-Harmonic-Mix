import SwiftUI

/// Opens Settings from inside a sheet or panel that shows a Discogs credentials error.
/// The sidebar's Settings sheet can't present over another sheet, so this owns its own.
struct OpenSettingsButton: View {
    var onDismiss: () -> Void = {}
    @Environment(SettingsViewModel.self) private var settings
    @Environment(CollectionViewModel.self) private var collection
    @State private var isPresented = false

    var body: some View {
        Button("Open Settings…") { isPresented = true }
            .sheet(isPresented: $isPresented, onDismiss: {
                collection.refreshConfiguration()
                onDismiss()
            }) {
                NavigationStack { SettingsView() }
                    .environment(settings)
                    .frame(minWidth: 440, minHeight: 340)
            }
    }
}
