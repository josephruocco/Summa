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

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var welcomeWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Defer to the next runloop tick so it runs after AppModel's init has
        // set the accessory activation policy; we override it below.
        DispatchQueue.main.async { [weak self] in self?.showWelcomeWindow() }
    }

    private func showWelcomeWindow() {
        // A menu-bar (accessory) app can't reliably front a window. Become a
        // regular app while the welcome window is up, then drop back to
        // accessory when it closes (windowWillClose).
        NSApp.setActivationPolicy(.regular)

        let root = WelcomeView(onDismiss: { [weak self] in self?.welcomeWindow?.close() })
            .environmentObject(AppModel.shared)

        let window = NSWindow(contentViewController: NSHostingController(rootView: root))
        window.title = "Summa"
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = .white
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        welcomeWindow = window
    }

    func windowWillClose(_ notification: Notification) {
        welcomeWindow = nil
        NSApp.setActivationPolicy(.accessory)
    }
}
