import AppKit
import Observation
import os

@Observable
final class WorkspaceEngine {
    private(set) var state: WorkspaceState
    private(set) var isRunning = false
    // True when no state file existed yet; the caller installs default shortcuts in that case.
    let createdDefaultState: Bool

    private let store: StateStore
    // Our own activate() calls fire didActivateApplication too; ignore those.
    private var suppressActivationUntil = Date.distantPast
    private var switchTask: Task<Void, Never>?
    private var adoptTasks: [String: Task<Void, Never>] = [:]

    init(store: StateStore = StateStore()) {
        self.store = store
        if let loaded = store.load() {
            state = loaded
            createdDefaultState = false
        } else {
            state = WorkspaceState()
            createdDefaultState = true
        }
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        reconcile()
        adoptPendingRunningApps()

        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(appDidActivate), name: NSWorkspace.didActivateApplicationNotification, object: nil)
        center.addObserver(self, selector: #selector(appDidLaunch), name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        center.addObserver(self, selector: #selector(appDidTerminate), name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(willTerminate), name: NSApplication.willTerminateNotification, object: nil)
        Log.engine.info("started, selected workspace \(self.state.selectedID)")

        // Restore the layout the user left, not just the selection.
        switchTo(state.selectedID)
    }

    // Keeps saved frames close to live: called on every app switch, HUD open and quit.
    func snapshotSelectedWorkspace() {
        snapshotFrames(of: state.selectedID)
        save()
    }

    // MARK: - Workspace list

    @discardableResult
    func addWorkspace() -> Workspace {
        let workspace = Workspace(id: state.nextID, name: "\(state.workspaces.count + 1)")
        state.nextID += 1
        state.workspaces.append(workspace)
        save()
        return workspace
    }

    func removeWorkspace(_ id: Int) {
        guard state.workspaces.count > 1, let index = state.index(of: id) else { return }
        state.workspaces.remove(at: index)
        state.pendingApps = state.pendingApps.filter { $0.value.workspaceID != id }
        if state.selectedID == id { state.selectedID = state.workspaces[0].id }
        save()
    }

    func rename(_ id: Int, to name: String) {
        state.update(id) { $0.name = name }
        save()
    }

    // MARK: - Commands

    func switchTo(_ id: Int) {
        guard let target = state.workspace(id) else { return }
        let started = CFAbsoluteTimeGetCurrent()

        snapshotFrames(of: state.selectedID)
        pruneDeadWindows()
        state.selectedID = id
        save()

        let slots = state.workspace(id)?.windows ?? target.windows
        let found = AXWindow.find(ids: slots.map(\.windowID))
        var appOrder: [pid_t] = []
        var windowsByApp: [pid_t: [(slot: WindowSlot, window: AXWindow)]] = [:]
        for slot in slots {
            guard let window = found[slot.windowID] else {
                Log.engine.warning("window \(slot.windowID) of \(slot.bundleID, privacy: .public) is alive but not reachable via AX")
                continue
            }
            if windowsByApp[window.pid] == nil { appOrder.append(window.pid) }
            windowsByApp[window.pid, default: []].append((slot, window))
        }

        launchPendingApps(for: id)

        switchTask?.cancel()
        switchTask = Task {
            suppressActivationUntil = .distantFuture
            defer { suppressActivationUntil = Date().addingTimeInterval(0.3) }

            // Least recently used app first, so the most recent one ends up active with its most
            // recent window on top.
            for pid in appOrder.reversed() {
                guard !Task.isCancelled else { return }
                await bringForward(windowsByApp[pid, default: []], pid: pid)
            }

            let elapsed = (CFAbsoluteTimeGetCurrent() - started) * 1000
            Log.engine.info("switched to \(id): \(slots.count) windows in \(appOrder.count) apps, \(elapsed, format: .fixed(precision: 1)) ms")
        }
    }

    // kAXRaiseAction only reorders within the owning app until that app is active; once it is, a
    // raise puts the window on top of everything. So: activate, wait for it to land, then raise.
    private func bringForward(_ entries: [(slot: WindowSlot, window: AXWindow)], pid: pid_t) async {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return }
        if !app.isActive {
            app.activate()
            for _ in 0..<15 where !app.isActive {
                try? await Task.sleep(for: .milliseconds(20))
            }
            if !app.isActive { Log.engine.warning("\(app.bundleIdentifier ?? "?", privacy: .public) did not activate in time") }
        }
        for entry in entries.reversed() {
            if !entry.window.isFullScreen, let current = entry.window.frame, !current.isClose(to: entry.slot.frame) {
                entry.window.setFrame(entry.slot.frame)
            }
            entry.window.raise()
        }
    }

    func toggleFocusedWindow(in id: Int) {
        guard let target = state.workspace(id) else { return }
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleID = app.bundleIdentifier,
              let window = AXWindow.focusedWindow(of: app.processIdentifier),
              window.isManageable,
              let frame = window.frame
        else {
            NSSound.beep()
            return
        }

        let alreadyThere = target.windows.contains { $0.windowID == window.id }
        state.remove(windowID: window.id)
        if alreadyThere {
            Log.engine.info("detached \(bundleID, privacy: .public) window \(window.id) from workspace \(id)")
        } else {
            let slot = WindowSlot(windowID: window.id, bundleID: bundleID, frame: frame)
            state.update(id) { $0.windows.insert(slot, at: 0) }
            AppIconService.shared.prefetch([bundleID])
            Log.engine.info("attached \(bundleID, privacy: .public) window \(window.id) to workspace \(id)")
        }
        save()
    }

    func pruneDeadWindows() {
        let live = AXWindow.liveWindowIDs()
        let before = state.workspaces.reduce(0) { $0 + $1.windows.count }
        state.removeAll { !live.contains($0.windowID) }
        let removed = before - state.workspaces.reduce(0) { $0 + $1.windows.count }
        if removed > 0 {
            Log.engine.info("pruned \(removed) closed windows")
            save()
        }
    }

    // MARK: - Notifications

    @objc private func willTerminate(_ notification: Notification) {
        snapshotSelectedWorkspace()
    }

    @objc private func appDidActivate(_ notification: Notification) {
        guard Date() >= suppressActivationUntil, let app = application(from: notification) else { return }
        // The previously active app just lost focus; its windows won't move until it's active again.
        snapshotSelectedWorkspace()
        guard let window = AXWindow.focusedWindow(of: app.processIdentifier),
              let workspaceID = state.workspaceID(containing: window.id)
        else { return }

        moveToFront(windowID: window.id, in: workspaceID)
        if workspaceID == state.selectedID {
            save()
        } else {
            Log.engine.info("focused window \(window.id) belongs to workspace \(workspaceID), following")
            switchTo(workspaceID)
        }
    }

    @objc private func appDidLaunch(_ notification: Notification) {
        guard let app = application(from: notification) else { return }
        adoptIfPending(app)
    }

    @objc private func appDidTerminate(_ notification: Notification) {
        guard let app = application(from: notification), let bundleID = app.bundleIdentifier else { return }
        let otherInstanceRunning = NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == bundleID && $0.processIdentifier != app.processIdentifier
        }
        guard !otherInstanceRunning else { return }
        guard let owner = state.workspaces.first(where: { $0.windows.contains { $0.bundleID == bundleID } }) else { return }

        let frames = owner.windows.filter { $0.bundleID == bundleID }.map(\.frame)
        state.pendingApps[bundleID] = PendingApp(workspaceID: owner.id, frames: frames)
        state.removeAll { $0.bundleID == bundleID }
        save()
        Log.engine.info("\(bundleID, privacy: .public) quit, will re-adopt into workspace \(owner.id)")
    }

    private func application(from notification: Notification) -> NSRunningApplication? {
        notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
    }

    // MARK: - Pending apps (quit / reboot recovery)

    private func adoptIfPending(_ app: NSRunningApplication) {
        guard let bundleID = app.bundleIdentifier, let pending = state.pendingApps[bundleID] else { return }
        adoptTasks[bundleID]?.cancel()
        adoptTasks[bundleID] = Task { [weak self] in
            // Windows usually appear shortly after didLaunch; give slow apps a few seconds.
            for _ in 0..<20 {
                guard let self, !Task.isCancelled, !app.isTerminated else { return }
                let windows = AXWindow.windows(of: app.processIdentifier).filter(\.isManageable)
                if !windows.isEmpty {
                    adopt(windows, bundleID: bundleID, pending: pending)
                    return
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
            Log.engine.warning("\(bundleID, privacy: .public) launched but showed no windows, keeping it pending")
        }
    }

    private func adopt(_ windows: [AXWindow], bundleID: String, pending: PendingApp) {
        state.pendingApps[bundleID] = nil
        state.removeAll { $0.bundleID == bundleID }
        guard state.workspace(pending.workspaceID) != nil else {
            save()
            return
        }

        var slots: [WindowSlot] = []
        for (index, window) in windows.enumerated() {
            let saved = index < pending.frames.count ? pending.frames[index] : nil
            if let saved, !window.isFullScreen { window.setFrame(saved) }
            guard let frame = saved ?? window.frame else { continue }
            slots.append(WindowSlot(windowID: window.id, bundleID: bundleID, frame: frame))
        }
        state.update(pending.workspaceID) { $0.windows.insert(contentsOf: slots, at: 0) }
        AppIconService.shared.prefetch([bundleID])
        save()
        Log.engine.info("adopted \(slots.count) \(bundleID, privacy: .public) windows into workspace \(pending.workspaceID)")
        enforceFrames(of: slots)

        if pending.workspaceID == state.selectedID, let pid = windows.first?.pid {
            let byID = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0) })
            let entries = slots.compactMap { slot in byID[slot.windowID].map { (slot: slot, window: $0) } }
            Task {
                suppressActivationUntil = .distantFuture
                defer { suppressActivationUntil = Date().addingTimeInterval(0.3) }
                await bringForward(entries, pid: pid)
            }
        }
    }

    // Apps restore their own window geometry shortly after launch, often after we've already placed
    // the window. Re-apply a few times until it sticks.
    private func enforceFrames(of slots: [WindowSlot]) {
        Task {
            for delay in [300, 1000, 2500] {
                try? await Task.sleep(for: .milliseconds(delay))
                let found = AXWindow.find(ids: slots.map(\.windowID))
                var fixed = 0
                for slot in slots {
                    guard let window = found[slot.windowID], !window.isFullScreen,
                          let current = window.frame, !current.isClose(to: slot.frame)
                    else { continue }
                    window.setFrame(slot.frame)
                    fixed += 1
                }
                if fixed > 0 { Log.engine.info("re-applied \(fixed) frames after \(delay) ms") }
            }
        }
    }

    // A workspace is a layout; switching to it brings back the apps that belong there.
    private func launchPendingApps(for workspaceID: Int) {
        for (bundleID, pending) in state.pendingApps where pending.workspaceID == workspaceID {
            let running = NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleID }
            guard !running, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { continue }
            Log.engine.info("launching \(bundleID, privacy: .public) for workspace \(workspaceID)")
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
                if let error {
                    Log.engine.error("failed to launch \(bundleID, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    private func adoptPendingRunningApps() {
        for app in NSWorkspace.shared.runningApplications {
            adoptIfPending(app)
        }
    }

    // Windows don't survive their app: drop what's gone, and remember the app for when it returns.
    private func reconcile() {
        let live = AXWindow.liveWindowIDs()
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))

        for workspace in state.workspaces {
            for slot in workspace.windows where !live.contains(slot.windowID) {
                guard !running.contains(slot.bundleID), state.pendingApps[slot.bundleID] == nil else { continue }
                let frames = workspace.windows.filter { $0.bundleID == slot.bundleID }.map(\.frame)
                state.pendingApps[slot.bundleID] = PendingApp(workspaceID: workspace.id, frames: frames)
            }
        }
        state.removeAll { !live.contains($0.windowID) }
        if state.selected == nil, let first = state.workspaces.first { state.selectedID = first.id }
        save()
        AppIconService.shared.prefetch(state.workspaces.flatMap(\.bundleIDs) + Array(state.pendingApps.keys))
    }

    // MARK: - Helpers

    private func snapshotFrames(of id: Int) {
        guard let workspace = state.workspace(id) else { return }
        let found = AXWindow.find(ids: workspace.windows.map(\.windowID))
        state.update(id) { workspace in
            for index in workspace.windows.indices {
                guard let window = found[workspace.windows[index].windowID],
                      !window.isFullScreen, !window.isMinimized,
                      let frame = window.frame
                else { continue }
                workspace.windows[index].frame = frame
            }
        }
    }

    private func moveToFront(windowID: CGWindowID, in workspaceID: Int) {
        state.update(workspaceID) { workspace in
            guard let index = workspace.windows.firstIndex(where: { $0.windowID == windowID }), index > 0 else { return }
            let slot = workspace.windows.remove(at: index)
            workspace.windows.insert(slot, at: 0)
        }
    }

    private func save() {
        store.save(state)
    }
}
