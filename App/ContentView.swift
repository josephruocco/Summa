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
                // Sign in with Apple button is hidden: the native flow can't be
                // signed for Developer ID distribution (the provisioning profile
                // won't carry the applesignin entitlement). The code is intact
                // in AppModel for a future Mac App Store or web-OAuth path.
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

// Welcome window shown on launch: the Summa logo and a single button that
// starts a session on the current window (the same as flipping the menu-bar
// toggle), then closes itself.
struct WelcomeView: View {
    @EnvironmentObject var model: AppModel
    var onDismiss: () -> Void = {}

    private var appVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0"
    }
    // Where the "What's New" link points. Update if you host release notes
    // elsewhere.
    private let whatsNewURL = URL(string: "https://github.com/josephruocco/Summa/releases/latest")!

    private let summaRed = Color(red: 0.72, green: 0.10, blue: 0.13)
    private let ink = Color(red: 0.11, green: 0.11, blue: 0.12)

    // Load the logo directly from the app bundle (a loose resource), which is
    // more reliable than the asset catalog for a single image.
    private var logoImage: NSImage? {
        if let url = Bundle.main.url(forResource: "summa-logo", withExtension: "png"),
           let img = NSImage(contentsOf: url) { return img }
        return NSImage(named: "SummaLogo")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let logo = logoImage {
                Image(nsImage: logo)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 300, height: 100)
                    .padding(.top, 6)
            } else {
                HStack(spacing: 0) {
                    Text("S")
                        .font(.system(size: 46, weight: .bold, design: .serif))
                        .foregroundStyle(.white)
                        .frame(width: 64, height: 64)
                        .background(RoundedRectangle(cornerRadius: 5).fill(summaRed))
                        .overlay(RoundedRectangle(cornerRadius: 5).inset(by: 4).stroke(.white, lineWidth: 1.5))
                    Text("UMMA")
                        .font(.system(size: 40, weight: .semibold, design: .serif))
                        .foregroundStyle(ink)
                        .padding(.leading, 8)
                }
                .padding(.top, 6)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Thank you for using Summa")
                    .font(.system(size: 20, weight: .semibold, design: .serif))
                    .foregroundStyle(ink)
                Text("Summa reads along with you and surfaces helpful notes worth knowing.")
                    .font(.system(size: 14, design: .serif))
                    .italic()
                    .foregroundStyle(ink.opacity(0.6))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                Task { await model.resumeAutomaticSession() }
                onDismiss()
            } label: {
                Text("Click to start")
                    .font(.system(size: 14.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(
                        LinearGradient(
                            colors: [summaRed.opacity(0.96), summaRed.opacity(0.82)],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .stroke(.white.opacity(0.25), lineWidth: 1)
                    )
                    .shadow(color: summaRed.opacity(0.35), radius: 9, y: 4)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
            .padding(.top, 2)
            .keyboardShortcut(.defaultAction)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("Version \(appVersion)")
                    Text("·")
                    Link("What's New", destination: whatsNewURL)
                        .tint(summaRed)
                }
                .font(.system(size: 11))
                Text("© 2026 Joseph Ruocco. All rights reserved.")
                    .font(.system(size: 10))
            }
            .foregroundStyle(ink.opacity(0.45))
            .padding(.top, 2)
        }
        .padding(.horizontal, 44)
        .padding(.top, 30)
        .padding(.bottom, 30)
        .frame(width: 460)
        .background(Color.white)
        .preferredColorScheme(.light)
        .onAppear { NSApp.activate(ignoringOtherApps: true) }
    }
}
