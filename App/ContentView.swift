import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            Divider()

            statusCard

            Divider()

            controls
        }
        .padding(14)
        .frame(width: 320)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            ZStack {
                Circle()
                    .fill(model.sessionOn ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.16))
                    .frame(width: 30, height: 30)

                Image(systemName: model.sessionOn ? "text.viewfinder" : "pause.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(model.sessionOn ? Color.accentColor : Color.secondary)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("SUMMA")
                    .font(.system(size: 13, weight: .semibold))
                Text(model.sessionOn ? "Quietly reading along" : "Paused")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Toggle("", isOn: $model.sessionOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .onChange(of: model.sessionOn) { _, on in
                    if on {
                        Task { await model.resumeAutomaticSession() }
                    } else {
                        model.stopSession()
                    }
                }
        }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Current window")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)

                Text(model.currentWindowLabel.isEmpty ? "Waiting for something readable…" : model.currentWindowLabel)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(2)
            }

            HStack(spacing: 10) {
                metricChip(title: "Vocab", value: model.lastHighlightCounts.vocab, tint: .green)
                metricChip(title: "Refs", value: model.lastHighlightCounts.ref, tint: .blue)
            }

            Text(model.status)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(3)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Menu {
                Toggle("Show Vocab Highlights", isOn: $model.showVocab)
                Toggle("Show Reference Highlights", isOn: $model.showRefs)
            } label: {
                Label("Highlight Options", systemImage: "slider.horizontal.3")
                    .font(.system(size: 12))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            VStack(alignment: .leading, spacing: 6) {
                Text("Annotation Layout")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)

                Picker("Annotation Layout", selection: $model.overlayLayout) {
                    ForEach(OverlayAnnotationLayout.allCases) { layout in
                        Text(layout.title).tag(layout)
                    }
                }
                .pickerStyle(.segmented)
            }

            Button {
                Task { await model.syncToFrontmostWindow(startIfNeeded: true) }
            } label: {
                Label("Retarget Current Window", systemImage: "scope")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.bordered)

            Button {
                model.chooseExportFolder()
            } label: {
                Label(model.hasExportFolder ? "Change Export Folder" : "Choose Export Folder", systemImage: "folder")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.bordered)

            Button {
                Task { await model.exportCatalog() }
            } label: {
                Label("Export Demo Catalog", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.bordered)
            .disabled(!model.sessionOn || !model.hasExportFolder)

            Button(role: .none) {
                NSApp.terminate(nil)
            } label: {
                Label("Quit SUMMA", systemImage: "xmark.circle")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
    }

    private func metricChip(title: String, value: Int, tint: Color) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(tint.opacity(0.9))
                .frame(width: 7, height: 7)
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer(minLength: 6)
            Text("\(value)")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(tint.opacity(0.10))
        )
    }
}
