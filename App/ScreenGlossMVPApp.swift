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

        Settings {
            EmptyView()
        }
    }
}
