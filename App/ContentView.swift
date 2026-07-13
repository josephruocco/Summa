import SwiftUI
import AppKit
import AuthenticationServices

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openSettings) private var openSettings

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
                HStack {
                    Text("Current window")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)

                    Spacer()

                    Button {
                        model.windowLocked.toggle()
                    } label: {
                        Image(systemName: model.windowLocked ? "pin.fill" : "pin.slash")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(model.windowLocked ? Color.accentColor : Color.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(model.windowLocked ? "Unlock — follow active window" : "Lock — stay on this window")
                    .disabled(!model.sessionOn)
                }

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
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            } label: {
                Label("Open Settings", systemImage: "gearshape")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.bordered)

            Button {
                Task { await model.syncToFrontmostWindow(startIfNeeded: true) }
            } label: {
                Label("Retarget Current Window", systemImage: "scope")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.bordered)

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

// The Settings window (opened from the menu panel's "Open Settings" button).
// Holds everything that used to clutter the menu: highlight toggles, premium
// AI account/credentials, training data, export, and feedback.
struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var hasTrainingData = TrainingDataStore.shared.hasData

    var body: some View {
        Form {
            Section("Highlights") {
                Toggle("Show vocab highlights", isOn: $model.showVocab)
                Toggle("Show reference highlights", isOn: $model.showRefs)
                Toggle("Premium AI annotations", isOn: $model.premiumAnnotations)
                Toggle("Show annotation debug", isOn: $model.showAnnotationDebug)
            }

            Section("Premium AI Account") {
                // Sign in with Apple is built and ready (see AppModel /
                // SignInWithAppleButton) but hidden until the "Sign in with
                // Apple" capability is enabled on the App ID and the entitlement
                // is re-added to the build. Until then, the beta access code is
                // the only sign-in. To re-enable, restore the SignInWithAppleButton
                // branch here.
                if let email = model.signedInEmail {
                    LabeledContent("Signed in") {
                        HStack {
                            Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                            Text(email)
                            Button("Sign Out") { model.signOut() }
                        }
                    }
                } else {
                    SecureField("Beta access code", text: $model.accessCode)
                }

                TextField("Proxy URL (https://…)", text: $model.proxyURL)
                    .textContentType(.URL)

                Text("No API key needed — requests go through Summa's server, and your key is never stored on this Mac.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                DisclosureGroup("Advanced: direct API key") {
                    SecureField("sk-ant-… (dev only)", text: $model.anthropicAPIKey)
                    Text("Calls Anthropic directly. Used only when no proxy URL is set.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Export") {
                Button(model.hasExportFolder ? "Change Export Folder…" : "Choose Export Folder…") {
                    model.chooseExportFolder()
                }
                Button("Export Demo Catalog") {
                    Task { await model.exportCatalog() }
                }
                .disabled(!model.sessionOn || !model.hasExportFolder)
            }

            Section("Training Data") {
                Text("Summa keeps a local log of which annotation you pick when multiple options are shown. Nothing is uploaded automatically.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("Reveal Training Log") {
                    if let url = TrainingDataStore.shared.storageFileURL {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                }
                Button("Clear Training Log", role: .destructive) {
                    TrainingDataStore.shared.clearAll()
                    hasTrainingData = false
                }
                .disabled(!hasTrainingData)
            }

            Section {
                Button("Send Feedback") {
                    if let url = URL(string: "https://summa-demo.josephruocco.net/feedback") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 600)
    }
}
