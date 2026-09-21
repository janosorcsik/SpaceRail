import KeyboardShortcuts
import SwiftUI

struct MenuContentView: View {
    let controller: AppController
    @Environment(\.openSettings) private var openSettings

    private var engine: WorkspaceEngine { controller.engine }

    var body: some View {
        if !engine.isRunning {
            Button("Allow Accessibility Access…") {
                controller.openAccessibilitySettings()
            }
            Divider()
        }

        ForEach(engine.state.workspaces) { workspace in
            Toggle(isOn: Binding(
                get: { engine.state.selectedID == workspace.id },
                set: { _ in engine.switchTo(workspace.id) }
            )) {
                Text(title(for: workspace))
            }
            .disabled(!engine.isRunning)
            // Display only: the app is never active, so this never fires; the Carbon hotkey does.
            .keyboardShortcut(KeyboardShortcuts.getShortcut(for: .switchTo(workspace.id))?.toSwiftUI)
        }

        Divider()

        Button("Show HUD") {
            controller.toggleHUD()
        }
        .keyboardShortcut(KeyboardShortcuts.getShortcut(for: .showHUD)?.toSwiftUI)

        Button("Settings…") {
            NSApp.activate()
            openSettings()
        }
        .keyboardShortcut(",")

        Divider()

        Button("Quit SpaceRail") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    private func title(for workspace: Workspace) -> String {
        let count = workspace.windows.count
        return count == 0 ? workspace.name : "\(workspace.name) — \(count) \(count == 1 ? "window" : "windows")"
    }
}
