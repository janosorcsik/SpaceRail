import AppKit
import KeyboardShortcuts
import Observation
import os

@Observable
final class AppController {
    static let hudAutoHideKey = "hudAutoHideSeconds"
    static let hudAutoHideDefault: Double = 2

    let engine = WorkspaceEngine()

    @ObservationIgnored private var panel: FloatingPanel?
    @ObservationIgnored private var hideTask: Task<Void, Never>?
    @ObservationIgnored private var permissionTimer: Timer?
    @ObservationIgnored private var registeredWorkspaceIDs: Set<Int> = []

    init() {
        UserDefaults.standard.register(defaults: [Self.hudAutoHideKey: Self.hudAutoHideDefault])

        for (position, workspace) in engine.state.workspaces.enumerated() {
            if engine.createdDefaultState {
                KeyboardShortcuts.installDefaults(for: workspace, position: position)
            }
            registerShortcuts(for: workspace.id)
        }
        KeyboardShortcuts.onKeyDown(for: .showHUD) { [weak self] in
            self?.toggleHUD()
        }

        startWhenTrusted()
    }

    // MARK: - Workspaces

    @discardableResult
    func addWorkspace() -> Workspace {
        let workspace = engine.addWorkspace()
        KeyboardShortcuts.installDefaults(for: workspace, position: engine.state.workspaces.count - 1)
        registerShortcuts(for: workspace.id)
        return workspace
    }

    func removeWorkspace(_ id: Int) {
        engine.removeWorkspace(id)
        KeyboardShortcuts.forget(workspaceID: id)
    }

    // MARK: - HUD

    func toggleHUD() {
        if panel?.isVisible == true {
            hideHUD()
        } else {
            showHUD()
        }
    }

    func showHUD() {
        if panel == nil {
            panel = FloatingPanel { [engine] in HUDView(engine: engine) }
        }
        engine.pruneDeadWindows()
        if engine.isRunning { engine.snapshotSelectedWorkspace() }
        AppIconService.shared.prefetch(engine.state.workspaces.flatMap(\.bundleIDs))
        panel?.showPanel()
        scheduleHUDHide()
    }

    func hideHUD() {
        hideTask?.cancel()
        panel?.hidePanel()
    }

    // Every user action restarts the countdown; 0 means it stays until toggled.
    private func scheduleHUDHide() {
        hideTask?.cancel()
        let seconds = UserDefaults.standard.double(forKey: Self.hudAutoHideKey)
        guard seconds > 0 else { return }
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.panel?.hidePanel()
        }
    }

    // MARK: - Permission

    func openAccessibilitySettings() {
        Permissions.ensureAccessibility(prompt: true)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // The system dialog adds us to the Accessibility list; then we poll until the user flips the switch,
    // so no restart is needed after granting.
    private func startWhenTrusted() {
        if Permissions.ensureAccessibility(prompt: true) {
            engine.start()
            return
        }
        Log.engine.notice("waiting for Accessibility permission")
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, Permissions.isAccessibilityTrusted else { return }
                self.permissionTimer?.invalidate()
                self.permissionTimer = nil
                self.engine.start()
            }
        }
    }

    // MARK: - Shortcuts

    // Handlers can't be unregistered; a removed workspace's shortcut is cleared instead, so the
    // handler never fires again. IDs are never reused.
    private func registerShortcuts(for id: Int) {
        guard !registeredWorkspaceIDs.contains(id) else { return }
        registeredWorkspaceIDs.insert(id)

        KeyboardShortcuts.onKeyDown(for: .switchTo(id)) { [weak self] in
            self?.whenRunning { engine in
                engine.switchTo(id)
                if self?.panel?.isVisible == true { self?.scheduleHUDHide() }
            }
        }
        KeyboardShortcuts.onKeyDown(for: .toggle(id)) { [weak self] in
            self?.whenRunning { engine in
                engine.toggleFocusedWindow(in: id)
                if self?.panel?.isVisible == true { self?.scheduleHUDHide() }
            }
        }
    }

    private func whenRunning(_ action: (WorkspaceEngine) -> Void) {
        guard engine.isRunning else {
            NSSound.beep()
            return
        }
        action(engine)
    }
}
