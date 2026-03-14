import SwiftUI
import AppKit

@main
struct ScreenGlossMVPApp: App {
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        MenuBarExtra("Summa", systemImage: model.sessionOn ? "text.viewfinder" : "text.viewfinder") {
            ContentView()
                .environmentObject(model)
                .task {
                    await model.startAutomaticModeIfNeeded()
                }
        }
        .menuBarExtraStyle(.window)

        Settings {
            EmptyView()
        }
    }
}
