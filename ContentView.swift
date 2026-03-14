import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("SUMMA")
                .font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                Text(model.currentWindowLabel.isEmpty ? "Waiting for an active window…" : model.currentWindowLabel)
                    .font(.system(size: 12, weight: .medium))
                Text(model.status)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Divider()

            Toggle("Session Running", isOn: $model.sessionOn)
                .onChange(of: model.sessionOn) { _, on in
                    if on {
                        Task { await model.resumeAutomaticSession() }
                    } else {
                        model.stopSession()
                    }
                }

            Toggle("Show Vocab", isOn: $model.showVocab)
            Toggle("Show References", isOn: $model.showRefs)

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("Highlights")
                    .font(.system(size: 12, weight: .semibold))
                Text("Vocab: \(model.lastHighlightCounts.vocab)   References: \(model.lastHighlightCounts.ref)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("Retarget Current Window") {
                    Task { await model.syncToFrontmostWindow(startIfNeeded: true) }
                }

                Button("Quit") {
                    NSApp.terminate(nil)
                }
            }
        }
        .padding(14)
        .frame(minWidth: 320)
    }
}
