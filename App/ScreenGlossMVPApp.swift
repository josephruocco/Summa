import SwiftUI
import AppKit

@main
struct ScreenGlossMVPApp: App {
    @StateObject private var model = AppModel.shared

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

        // Welcome window: shown on launch, with the logo and a one-click
        // "start my session on the current window" button.
        Window("Summa", id: "welcome") {
            WelcomeView()
                .environmentObject(model)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        Settings {
            SettingsView()
                .environmentObject(model)
        }
    }
}
