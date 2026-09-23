import AppKit
import KeyboardShortcuts
import Observation
import os

@Observable
final class AppController {
    static let hudAutoHideKey = "hudAutoHideSeconds"
    static let hudAutoHideDefault: Double = 2
    static let hudFlashOnSwitchKey = "hudFlashOnSwitch"
    // Set when the lesson has been *acted on* (first attach or HUD toggle), not when it was shown:
    // quitting halfway through means it plays again.
    private static let welcomeCompletedKey = "didCompleteWelcome"
    // Long enough to read the highlighted card, short enough not to feel like a window.
    private static let flashDuration: Duration = .seconds(1)

    let engine = WorkspaceEngine()

    @ObservationIgnored private var panel: FloatingPanel?
    @ObservationIgnored private var hideTask: Task<Void, Never>?
    @ObservationIgnored private var hideDeadline: ContinuousClock.Instant?
    @ObservationIgnored private let toastModel = ToastModel()
    @ObservationIgnored private var toastPanel: FloatingPanel?
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    @ObservationIgnored private var permissionTask: Task<Void, Never>?
    @ObservationIgnored private var registeredWorkspaceIDs: Set<Int> = []
    // First run: the HUD and the hint stay up until the user has done one thing with them.
    @ObservationIgnored private var isWelcoming = false
    @ObservationIgnored private var welcomeHint: Feedback?

    init() {
        UserDefaults.standard.register(defaults: [
            Self.hudAutoHideKey: Self.hudAutoHideDefault,
            Self.hudFlashOnSwitchKey: true,
        ])

        for workspace in engine.state.workspaces {
            KeyboardShortcuts.installDefaultsIfNeeded(for: workspace, among: engine.state.workspaces)
            registerShortcuts(for: workspace.id)
        }
        KeyboardShortcuts.onKeyDown(for: .showHUD) { [weak self] in
            self?.toggleHUD()
        }

        engine.onFeedback = { [weak self] feedback in
            self?.handle(feedback)
        }

        // Starting the engine can emit feedback and open panels; that must not happen while the
        // SwiftUI scene that owns this object is still being built.
        Task { startWhenTrusted() }
    }

    // MARK: - Workspaces

    @discardableResult
    func addWorkspace() -> Workspace {
        let workspace = engine.addWorkspace()
        KeyboardShortcuts.installDefaultsIfNeeded(for: workspace, among: engine.state.workspaces)
        registerShortcuts(for: workspace.id)
        return workspace
    }

    func removeWorkspace(_ id: Int) {
        engine.removeWorkspace(id)
        KeyboardShortcuts.forget(workspaceID: id)
    }

    // MARK: - Feedback

    private func handle(_ feedback: Feedback) {
        if isWelcoming, case .added = feedback { endWelcome() }
        switch feedback {
        case .switched:
            // The HUD itself is the confirmation: the target card lights up.
            if panel?.isVisible == true {
                scheduleHUDHide()
            } else if UserDefaults.standard.bool(forKey: Self.hudFlashOnSwitchKey) {
                showHUD(for: Self.flashDuration)
            }
        default:
            showToast(feedback)
        }
    }

    private func showToast(_ feedback: Feedback) {
        // A hint is there to be read; don't let a passing confirmation replace it.
        if case .hint = toastModel.feedback, toastPanel?.isVisible == true, !feedback.isRefusal { return }
        if toastPanel == nil {
            toastPanel = FloatingPanel(placement: .bottom) { [toastModel] in ToastView(model: toastModel) }
        }
        toastModel.feedback = feedback
        toastPanel?.showPanel()

        toastTask?.cancel()
        if isWelcoming, case .hint = feedback { return }
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: feedback.duration)
            guard !Task.isCancelled, let self else { return }
            // A refusal during the lesson steps aside for the hint again instead of leaving the
            // HUD up with nothing explaining it.
            if isWelcoming, let welcomeHint {
                showToast(welcomeHint)
            } else {
                toastPanel?.hidePanel()
            }
        }
    }

    // MARK: - HUD

    func toggleHUD() {
        if isWelcoming { endWelcome() }
        if panel?.isVisible == true {
            hideHUD()
        } else {
            showHUD()
        }
    }

    // Without a duration the user's auto-hide setting applies; with one, it's a flash.
    func showHUD(for duration: Duration? = nil) {
        if panel == nil {
            panel = FloatingPanel { [engine] in HUDView(engine: engine) }
        }
        engine.pruneDeadWindows()
        if engine.isRunning { engine.snapshotSelectedWorkspace() }
        AppIconService.shared.prefetch(engine.state.workspaces.flatMap(\.bundleIDs))
        panel?.showPanel()
        scheduleHUDHide(after: duration)
    }

    func hideHUD() {
        hideTask?.cancel()
        hideDeadline = nil
        panel?.hidePanel()
    }

    // Every user action restarts the countdown; a setting of 0 means it stays until toggled.
    // A countdown never shortens one already running, so a welcome or flash isn't cut off.
    private func scheduleHUDHide(after duration: Duration? = nil) {
        guard !isWelcoming else { return }
        let seconds = UserDefaults.standard.double(forKey: Self.hudAutoHideKey)
        let delay = duration ?? (seconds > 0 ? .seconds(seconds) : nil)
        guard let delay else {
            hideTask?.cancel()
            hideDeadline = nil
            return
        }
        let deadline = ContinuousClock.now + delay
        if let hideDeadline, hideDeadline > deadline { return }
        hideTask?.cancel()
        hideDeadline = deadline
        hideTask = Task { [weak self] in
            try? await Task.sleep(until: deadline)
            guard !Task.isCancelled else { return }
            self?.hideDeadline = nil
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
            start()
            return
        }
        Log.engine.notice("waiting for Accessibility permission")
        permissionTask = Task {
            while !Permissions.isAccessibilityTrusted {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
            }
            start()
        }
    }

    // Show where things are and the one gesture that matters, and leave both up until the user has
    // made that gesture: this is the lesson. Someone who already has windows attached knows it.
    private func start() {
        if !UserDefaults.standard.bool(forKey: Self.welcomeCompletedKey) {
            let hasAttachments = engine.state.workspaces.contains { !$0.windows.isEmpty } || !engine.state.pendingApps.isEmpty
            if hasAttachments {
                UserDefaults.standard.set(true, forKey: Self.welcomeCompletedKey)
            } else {
                welcome()
            }
        }
        engine.start()
    }

    private func welcome() {
        guard let first = engine.state.workspaces.first else { return }
        isWelcoming = true
        showHUD()
        let shortcut = KeyboardShortcuts.getShortcut(for: .toggle(first.id))?.description ?? "the Add / remove shortcut"
        let hint = Feedback.hint("Press \(shortcut) in any window to add it to workspace “\(first.name)”. Shortcuts and names are in Settings.")
        welcomeHint = hint
        showToast(hint)
    }

    private func endWelcome() {
        isWelcoming = false
        welcomeHint = nil
        UserDefaults.standard.set(true, forKey: Self.welcomeCompletedKey)
        toastTask?.cancel()
        toastPanel?.hidePanel()
        scheduleHUDHide()
    }

    // MARK: - Shortcuts

    // Handlers can't be unregistered; a removed workspace's shortcut is cleared instead, so the
    // handler never fires again. IDs are never reused.
    private func registerShortcuts(for id: Int) {
        guard !registeredWorkspaceIDs.contains(id) else { return }
        registeredWorkspaceIDs.insert(id)

        KeyboardShortcuts.onKeyDown(for: .switchTo(id)) { [weak self] in
            self?.whenRunning { $0.switchTo(id) }
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
            showToast(.refused(.noPermission))
            return
        }
        action(engine)
    }
}
