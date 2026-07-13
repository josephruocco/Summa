import SwiftUI
import AppKit

@main
struct ScreenGlossMVPApp: App {
    @StateObject private var model = AppModel.shared
    // Shows the welcome window at launch. A SwiftUI Window scene doesn't
    // reliably open on launch for a menu-bar (accessory) app, so we manage a
    // real NSWindow from the app delegate instead.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            ContentView()
                .environmentObject(model)
                .task {
                    await model.startAutomaticModeIfNeeded()
                }
        } label: {
            Label("SUMMA", systemImage: model.sessionOn ? "book.closed.fill" : "book.closed")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var welcomeWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        showWelcomeWindow()
    }

    private func showWelcomeWindow() {
        let root = WelcomeView(onDismiss: { [weak self] in self?.welcomeWindow?.close() })
            .environmentObject(AppModel.shared)

        let window = NSWindow(contentViewController: NSHostingController(rootView: root))
        window.title = "Summa"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        welcomeWindow = window
    }
}
