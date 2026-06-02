import SwiftUI
import SwiftData

struct SetBuilderView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AudioPlaybackController.self) private var playback
    @Environment(CollectionViewModel.self) private var viewModel

    @Query private var allCollectionEntities: [CollectionItemEntity]
    @Query private var allTrackEntities: [TrackEntity]
    @Query private var allFeatures: [RecordingFeaturesEntity]
    @Query private var allSets: [SetlistEntity]

    // State — Current Track is the user's focus
    @State private var currentTrack: MixTrack? = nil

    // State — pool/setlist management (filled in later steps)
    @AppStorage("setBuilderActiveSetID") private var activeSetID: String = ""
    @State private var activeSet: SetlistEntity? = nil

    // Harmonic strip controls
    @AppStorage("setBuilderBpmTolerancePct") private var bpmTolerancePct: Double = 5.0
    @State private var visibleGroups: Set<HarmonicGroup> = Set(HarmonicGroup.allCases)

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar placeholder — filled in step 5
            HStack {
                Text("Set Builder").font(.headline)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            // Current Track section — filled in step 3
            VStack {
                if currentTrack == nil {
                    Text("Tap a track in your collection below to begin")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Text("Current Track placeholder")
                }
            }
            .frame(height: 120)

            Divider()

            // Harmonic strip section — filled in step 4
            VStack {
                if currentTrack == nil {
                    Color.clear
                } else {
                    Text("Compatible tracks placeholder")
                }
            }
            .frame(height: 220)

            Divider()

            // Collection grid section — filled in step 2
            Text("Collection grid placeholder")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
