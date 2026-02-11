import SwiftUI
import ScreenCaptureKit

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button("Refresh Windows") {
                    Task { await model.refreshWindows() }
                }

                Picker("Target Window", selection: $model.selectedWindowID) {
                    Text("None").tag(UInt32?.none)
                    ForEach(model.windows, id: \.windowID) { w in
                        Text(model.windowLabel(w)).tag(Optional(w.windowID))
                    }
                }
                .frame(minWidth: 520)

                Toggle("Session", isOn: $model.sessionOn)
                    .onChange(of: model.sessionOn) { _, on in
                        if on {
                            Task { await model.startSession() }
                        } else {
                            model.stopSession()
                        }
                    }
            }

            HStack(spacing: 18) {
                VStack(alignment: .leading) {
                    Text("Highlights")
                        .font(.headline)
                    Text("Vocab: \(model.lastHighlightCounts.vocab)   References: \(model.lastHighlightCounts.ref)")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Show Vocab", isOn: $model.showVocab)
                Toggle("Show References", isOn: $model.showRefs)
            }

            Divider()

            Text(model.status)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            Spacer()
        }
        .padding(16)
        .task {
            await model.refreshWindows()
        }
    }
}
