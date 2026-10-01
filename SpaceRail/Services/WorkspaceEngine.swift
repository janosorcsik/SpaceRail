import AppKit
import Observation
import os

@Observable
final class WorkspaceEngine {
    private(set) var state: WorkspaceState
    private(set) var isRunning = false
    // The one seam to the UI: every confirmation, refusal and self-initiated action goes through here.
    @ObservationIgnored var onFeedback: ((Feedback) -> Void)?

    private let store: StateStore
    // Our own activate() calls fire didActivateApplication too; ignore those. Several tasks can be
    // activating at once (a switch cancelled by the next, an adoption), so they're counted: the last
    // one to finish opens a short grace period for notifications still in flight.
    private var ownActivations = 0
    private var suppressActivationUntil = Date.distantPast
    private var isSuppressingActivation: Bool { ownActivations > 0 || Date() < suppressActivationUntil }
    private var switchTask: Task<Void, Never>?
    private var adoptTasks: [String: Task<Void, Never>] = [:]
    private var saveTask: Task<Void, Never>?

    init(store: StateStore = StateStore()) {
        self.store = store
        state = store.load() ?? WorkspaceState()
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        AXWindow.configureMessagingTimeout()
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
        state.removeWorkspace(id)
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
        let list = WindowList.current()

        snapshotFrames(of: state.selectedID, in: list)
        pruneDeadWindows(in: list)
        state.selectedID = id
        save()

        let slots = state.workspace(id)?.windows ?? target.windows
        let found = AXWindow.find(ids: slots.map(\.windowID), in: list)
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
        onFeedback?(.switched(workspace: target.name))

        switchTask?.cancel()
        switchTask = Task {
            beginOwnActivations()
            defer { endOwnActivations() }

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

    private func beginOwnActivations() {
        ownActivations += 1
    }

    private func endOwnActivations() {
        ownActivations -= 1
        if ownActivations == 0 { suppressActivationUntil = Date().addingTimeInterval(0.3) }
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
        let screens = Screens.visibleFrames()
        for entry in entries.reversed() {
            let target = Screens.placeOnScreen(entry.slot.frame, screens: screens)
            if !entry.window.isFullScreen, let current = entry.window.frame, !current.isClose(to: target) {
                entry.window.setFrame(target)
            }
            entry.window.raise()
        }
    }

    func toggleFocusedWindow(in id: Int) {
        guard let target = state.workspace(id) else { return }
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleID = app.bundleIdentifier,
              let window = AXWindow.focusedWindow(of: app.processIdentifier)
        else {
            onFeedback?(.refused(.noFocusedWindow))
            return
        }
        guard window.isManageable, let frame = window.frame else {
            onFeedback?(.refused(.notAWindow))
            return
        }

        let appName = app.localizedName ?? AppIconService.shared.name(for: bundleID)
        let alreadyThere = target.windows.contains { $0.windowID == window.id }
        state.removeAll { $0.windowID == window.id }
        if alreadyThere {
            Log.engine.info("detached \(bundleID, privacy: .public) window \(window.id) from workspace \(id)")
            onFeedback?(.removed(app: appName, workspace: target.name))
        } else {
            let slot = WindowSlot(windowID: window.id, bundleID: bundleID, frame: frame)
            state.update(id) { $0.windows.insert(slot, at: 0) }
            AppIconService.shared.prefetch([bundleID])
            Log.engine.info("attached \(bundleID, privacy: .public) window \(window.id) to workspace \(id)")
            onFeedback?(.added(app: appName, workspace: target.name))
        }
        save()
    }

    func pruneDeadWindows(in list: WindowList = .current()) {
        let pendingBefore = state.pendingApps.count
        let removed = state.retireDeadWindows(in: list, atLaunch: false)
        if removed > 0 || state.pendingApps.count != pendingBefore {
            Log.engine.info("pruned \(removed) closed windows")
            save()
        }
    }

    // MARK: - Notifications

    @objc private func willTerminate(_ notification: Notification) {
        snapshotFrames(of: state.selectedID)
        saveNow()
    }

    @objc private func appDidActivate(_ notification: Notification) {
        guard !isSuppressingActivation, let app = application(from: notification) else { return }
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
            if let target = state.workspace(workspaceID) {
                onFeedback?(.following(app: app.localizedName ?? "window", workspace: target.name))
            }
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
        adoptTasks[bundleID]?.cancel()
        guard state.workspaces.contains(where: { $0.bundleIDs.contains(bundleID) }) else { return }

        state.makePending(bundleID)
        save()
        let workspaces = state.pendingApps[bundleID]?.workspaceIDs.sorted() ?? []
        Log.engine.info("\(bundleID, privacy: .public) quit, will re-adopt into workspaces \(workspaces, privacy: .public)")
    }

    private func application(from notification: Notification) -> NSRunningApplication? {
        notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
    }

    // MARK: - Pending apps (quit / reboot recovery)

    // Apps restore their windows one after another, and slow ones take a few seconds to show any.
    // Keep collecting until every saved window has a taker or the app has had its chance.
    private func adoptIfPending(_ app: NSRunningApplication) {
        guard let bundleID = app.bundleIdentifier, state.pendingApps[bundleID] != nil else { return }
        adoptTasks[bundleID]?.cancel()
        adoptTasks[bundleID] = Task {
            defer { if !Task.isCancelled { adoptTasks[bundleID] = nil } }
            var adopted = 0
            for _ in 0..<20 {
                guard !Task.isCancelled, !app.isTerminated, state.pendingApps[bundleID] != nil else { return }
                let known = Set(state.workspaces.flatMap(\.windows).map(\.windowID))
                let fresh = AXWindow.windows(of: app.processIdentifier).filter { !known.contains($0.id) && $0.isManageable }
                if !fresh.isEmpty { adopted += adopt(fresh, bundleID: bundleID) }
                try? await Task.sleep(for: .milliseconds(500))
            }
            guard !Task.isCancelled, state.pendingApps[bundleID] != nil else { return }
            if adopted > 0 {
                // It came back with fewer windows than it had; the rest aren't coming.
                state.pendingApps[bundleID] = nil
                save()
            } else {
                Log.engine.warning("\(bundleID, privacy: .public) launched but showed no windows, keeping it pending")
            }
        }
    }

    // Each new window takes the next saved slot: its workspace and its frame. Windows beyond the
    // saved ones stay free; the app had fewer windows in workspaces than it restores now.
    @discardableResult
    private func adopt(_ windows: [AXWindow], bundleID: String) -> Int {
        guard var pending = state.pendingApps[bundleID] else { return 0 }
        var adopted: [(workspaceID: Int, slot: WindowSlot, window: AXWindow)] = []
        let screens = Screens.visibleFrames()
        for window in windows {
            guard !pending.slots.isEmpty else { break }
            let saved = pending.slots.removeFirst()
            guard state.workspace(saved.workspaceID) != nil else { continue }
            let frame = Screens.placeOnScreen(saved.frame, screens: screens)
            if !window.isFullScreen { window.setFrame(frame) }
            adopted.append((saved.workspaceID, WindowSlot(windowID: window.id, bundleID: bundleID, frame: frame), window))
        }
        state.pendingApps[bundleID] = pending.slots.isEmpty ? nil : pending
        for (workspaceID, entries) in Dictionary(grouping: adopted, by: \.workspaceID) {
            state.update(workspaceID) { $0.windows.insert(contentsOf: entries.map(\.slot), at: 0) }
        }
        AppIconService.shared.prefetch([bundleID])
        save()

        guard let first = adopted.first else { return 0 }
        let slots = adopted.map(\.slot)
        Log.engine.info("adopted \(slots.count) \(bundleID, privacy: .public) windows into workspaces \(Set(adopted.map(\.workspaceID)).sorted(), privacy: .public)")
        if let target = state.workspace(first.workspaceID) {
            onFeedback?(.returned(app: AppIconService.shared.name(for: bundleID), workspace: target.name))
        }
        enforceFrames(of: slots)

        let selected = adopted.filter { $0.workspaceID == state.selectedID }.map { (slot: $0.slot, window: $0.window) }
        if let pid = selected.first?.window.pid {
            Task {
                beginOwnActivations()
                defer { endOwnActivations() }
                await bringForward(selected, pid: pid)
            }
        }
        return slots.count
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

    // A workspace is a layout; switching to it brings back the apps that belong there. One that is
    // already running (it came back without windows earlier) gets another chance to be adopted.
    private func launchPendingApps(for workspaceID: Int) {
        for bundleID in state.pendingBundleIDs(in: workspaceID) {
            if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID }) {
                if adoptTasks[bundleID]?.isCancelled ?? true { adoptIfPending(app) }
                continue
            }
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
                Log.engine.notice("\(bundleID, privacy: .public) is no longer installed, forgetting it")
                state.pendingApps[bundleID] = nil
                save()
                continue
            }
            Log.engine.info("launching \(bundleID, privacy: .public) for workspace \(workspaceID)")
            onFeedback?(.launching(app: AppIconService.shared.name(for: bundleID)))
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            Task {
                do {
                    try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
                } catch {
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

    // Drop what's gone and remember the apps for when they return. At launch an app that is running
    // but has none of its saved windows was restarted while we weren't looking (typically a reboot
    // with the app opening at login before us): it's re-adopted right away.
    private func reconcile() {
        let list = WindowList.current()
        state.retireDeadWindows(in: list, atLaunch: true)
        if state.selected == nil, let first = state.workspaces.first { state.selectedID = first.id }
        save()
        AppIconService.shared.prefetch(state.workspaces.flatMap(\.bundleIDs) + Array(state.pendingApps.keys))
    }

    // MARK: - Helpers

    private func snapshotFrames(of id: Int, in list: WindowList = .current()) {
        guard let workspace = state.workspace(id) else { return }
        let found = AXWindow.find(ids: workspace.windows.map(\.windowID), in: list)
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

    // State changes on every app switch and every keystroke in a name field; coalesce the disk writes.
    private func save() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            store.save(state)
        }
    }

    private func saveNow() {
        saveTask?.cancel()
        store.save(state)
    }
}
