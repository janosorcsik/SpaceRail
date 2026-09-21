import SwiftUI

@main
struct SpaceRailApp: App {
    @State private var controller = AppController()

    var body: some Scene {
        MenuBarExtra("SpaceRail", systemImage: "square.grid.2x2") {
            MenuContentView(controller: controller)
        }

        Settings {
            SettingsView(controller: controller)
        }
        .windowResizability(.contentSize)
    }
}
