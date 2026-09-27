import SwiftUI

struct SyncProgressView: View {
    @Environment(SyncOrchestrator.self) private var orchestrator
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                if orchestrator.isSyncing {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 16, height: 16)
                } else {
                    Image(systemName: orchestrator.lastResult.hasPrefix("Sync failed") ? "xmark.circle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(orchestrator.lastResult.hasPrefix("Sync failed") ? Color.red : Color.green)
                        .font(.title3)
                }
                Text(orchestrator.isSyncing ? orchestrator.syncStatus : orchestrator.lastResult)
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !orchestrator.isSyncing {
                HStack {
                    Spacer()
                    Button("Done") { dismiss() }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(24)
        .frame(minWidth: 380, maxWidth: 520)
        .alert(
            "Analyze \(orchestrator.pendingAnalysisCount) files?",
            isPresented: Binding(
                get: { orchestrator.showAnalysisConfirmation },
                set: { _ in }
            )
        ) {
            Button("Analyze") { orchestrator.confirmAnalysis() }
            Button("Skip", role: .cancel) { orchestrator.skipAnalysis() }
        } message: {
            Text("Found \(orchestrator.pendingAnalysisCount) new unanalyzed files. This may take a while. Proceed?")
        }
    }
}
