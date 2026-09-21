import KeyboardShortcuts
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    let controller: AppController

    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
            WorkspacesSettingsView(controller: controller)
                .tabItem { Label("Workspaces", systemImage: "square.grid.2x2") }
        }
        .frame(width: 560)
    }
}

// MARK: - General

private struct GeneralSettingsView: View {
    @AppStorage(AppController.hudAutoHideKey) private var hudAutoHide = AppController.hudAutoHideDefault
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchAtLoginError: String?

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        setLaunchAtLogin(enabled)
                    }
                if let launchAtLoginError {
                    Text(launchAtLoginError)
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            }

            Section("HUD") {
                KeyboardShortcuts.Recorder("Show or hide", name: .showHUD)
                Picker("Hide automatically after", selection: $hudAutoHide) {
                    Text("Never").tag(0.0)
                    Text("1 second").tag(1.0)
                    Text("2 seconds").tag(2.0)
                    Text("3 seconds").tag(3.0)
                    Text("5 seconds").tag(5.0)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = error.localizedDescription
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

// MARK: - Workspaces

private struct WorkspacesSettingsView: View {
    let controller: AppController
    @State private var selection: Workspace.ID?
    @State private var workspaceToRemove: Workspace?

    private var engine: WorkspaceEngine { controller.engine }

    // Only ask when there is something to lose: an empty workspace just goes.
    private func requestRemoval(of id: Workspace.ID) {
        guard let workspace = engine.state.workspace(id) else { return }
        let hasPending = engine.state.pendingApps.values.contains { $0.workspaceID == id }
        if workspace.windows.isEmpty && !hasPending {
            remove(workspace)
        } else {
            workspaceToRemove = workspace
        }
    }

    private func remove(_ workspace: Workspace) {
        controller.removeWorkspace(workspace.id)
        selection = nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Table(engine.state.workspaces, selection: $selection) {
                TableColumn("Name") { workspace in
                    NameCell(workspace: workspace) { engine.rename(workspace.id, to: $0) }
                }
                .width(min: 100, ideal: 140)

                TableColumn("Switch") { workspace in
                    KeyboardShortcuts.Recorder(for: .switchTo(workspace.id))
                }
                .width(150)

                TableColumn("Attach") { workspace in
                    KeyboardShortcuts.Recorder(for: .toggle(workspace.id))
                }
                .width(150)
            }
            .tableStyle(.bordered)
            .frame(minHeight: 220)

            HStack(spacing: 12) {
                ControlGroup {
                    Button {
                        let workspace = controller.addWorkspace()
                        selection = workspace.id
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add workspace")

                    Button {
                        if let selection { requestRemoval(of: selection) }
                    } label: {
                        Image(systemName: "minus")
                    }
                    .disabled(selection == nil || engine.state.workspaces.count <= 1)
                    .accessibilityLabel("Remove workspace")
                }
                .fixedSize()
                .confirmationDialog(
                    "Remove “\(workspaceToRemove?.name ?? "")”?",
                    isPresented: Binding(
                        get: { workspaceToRemove != nil },
                        set: { if !$0 { workspaceToRemove = nil } }
                    ),
                    titleVisibility: .visible,
                    presenting: workspaceToRemove
                ) { workspace in
                    Button("Remove Workspace", role: .destructive) { remove(workspace) }
                } message: { workspace in
                    Text("Its \(workspace.windows.count) windows stay open but will no longer be grouped, and its shortcuts are cleared.")
                }

                Text("Switch brings the workspace's windows to the front. Attach toggles the focused window in or out of it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
    }
}

private struct NameCell: View {
    let workspace: Workspace
    let rename: (String) -> Void

    @State private var name: String

    init(workspace: Workspace, rename: @escaping (String) -> Void) {
        self.workspace = workspace
        self.rename = rename
        _name = State(initialValue: workspace.name)
    }

    var body: some View {
        TextField("Name", text: $name)
            .textFieldStyle(.plain)
            .labelsHidden()
            .onSubmit(commit)
            .onChange(of: name) { _, _ in commit() }
            .accessibilityLabel("Workspace name")
    }

    private func commit() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != workspace.name else { return }
        rename(trimmed)
    }
}
