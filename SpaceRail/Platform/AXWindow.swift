import AppKit
import ApplicationServices
import os

// Private but universally used (AltTab, Hammerspoon, AeroSpace): the only way to get a CGWindowID
// out of an AX window element.
@_silgen_name("_AXUIElementGetWindow")
private nonisolated func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

struct AXWindow {
    let element: AXUIElement
    let id: CGWindowID
    let pid: pid_t

    // MARK: - Lookup

    static func windows(of pid: pid_t) -> [AXWindow] {
        let app = AXUIElementCreateApplication(pid)
        var value: AnyObject?
        let error = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value)
        guard error == .success else {
            Log.ax.debug("windows(of: \(pid)) failed: \(error.rawValue)")
            return []
        }
        guard let raw = value as? [AXUIElement] else {
            Log.ax.debug("windows(of: \(pid)) returned unexpected type: \(String(describing: type(of: value)), privacy: .public)")
            return []
        }
        return raw.compactMap { element in
            guard let id = windowID(of: element) else {
                Log.ax.debug("windows(of: \(pid)) element without window id")
                return nil
            }
            return AXWindow(element: element, id: id, pid: pid)
        }
    }

    static func focusedWindow(of pid: pid_t) -> AXWindow? {
        let app = AXUIElementCreateApplication(pid)
        guard let element = element(copyAttribute(kAXFocusedWindowAttribute, from: app)),
              let id = windowID(of: element)
        else { return nil }
        return AXWindow(element: element, id: id, pid: pid)
    }

    // Resolves many IDs at once: one AX enumeration per owning app. Missing IDs are closed windows.
    static func find(ids: [CGWindowID], in list: WindowList = .current()) -> [CGWindowID: AXWindow] {
        var byPID: [pid_t: Set<CGWindowID>] = [:]
        for id in ids {
            if let pid = list.owners[id] {
                byPID[pid, default: []].insert(id)
            } else {
                Log.ax.debug("find: window \(id) has no owner in CGWindowList (\(list.owners.count) windows listed)")
            }
        }
        var result: [CGWindowID: AXWindow] = [:]
        for (pid, wanted) in byPID {
            let windows = windows(of: pid)
            for window in windows where wanted.contains(window.id) {
                result[window.id] = window
            }
            let missing = wanted.subtracting(windows.map(\.id))
            if !missing.isEmpty {
                let listed = windows.map { String($0.id) }.joined(separator: ",")
                Log.ax.debug("find: pid \(pid) AX lists [\(listed, privacy: .public)], missing \(missing.map(String.init).joined(separator: ","), privacy: .public)")
            }
        }
        return result
    }

    // MARK: - Attributes

    var frame: CGRect? {
        guard let origin = pointAttribute(kAXPositionAttribute),
              let size = sizeAttribute(kAXSizeAttribute)
        else { return nil }
        return CGRect(origin: origin, size: size)
    }

    var title: String? {
        Self.copyAttribute(kAXTitleAttribute, from: element) as? String
    }

    var isFullScreen: Bool {
        Self.copyAttribute("AXFullScreen", from: element) as? Bool ?? false
    }

    var isMinimized: Bool {
        Self.copyAttribute(kAXMinimizedAttribute, from: element) as? Bool ?? false
    }

    // A regular, user-facing window that we can move: not a sheet, popover, modal or system dialog.
    var isManageable: Bool {
        guard stringAttribute(kAXRoleAttribute) == kAXWindowRole as String,
              Self.copyAttribute(kAXModalAttribute, from: element) as? Bool != true,
              stringAttribute(kAXSubroleAttribute) != kAXSystemDialogSubrole as String,
              isIndependentUserWindow
        else { return false }
        return frame != nil && isAttributeSettable(kAXPositionAttribute)
    }

    private var isIndependentUserWindow: Bool {
        if stringAttribute(kAXSubroleAttribute) == kAXStandardWindowSubrole as String { return true }
        return [kAXCloseButtonAttribute, kAXMinimizeButtonAttribute, kAXZoomButtonAttribute, kAXFullScreenButtonAttribute]
            .contains { Self.copyAttribute($0, from: element) != nil }
    }

    // MARK: - Actions

    // AX has no atomic frame setter. Resize before and after the move so the window fits on the
    // target display regardless of which direction it is moving.
    @discardableResult
    func setFrame(_ frame: CGRect) -> Bool {
        var size = frame.size
        var origin = frame.origin
        guard let sizeValue = AXValueCreate(.cgSize, &size),
              let originValue = AXValueCreate(.cgPoint, &origin)
        else { return false }

        // Fixed-size windows (Calculator) reject the size but still take the position.
        AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sizeValue)
        let moved = AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, originValue)
        AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sizeValue)
        if moved != .success { Log.ax.warning("setFrame failed for window \(id): \(moved.rawValue)") }
        return moved == .success
    }

    // Only orders within the owning app until the app is active; then it goes to the global top.
    // Some apps report an error here yet still raise, so the result is only logged at debug level.
    @discardableResult
    func raise() -> Bool {
        if isMinimized {
            AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }
        AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
        let result = AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        if result != .success { Log.ax.debug("raise returned \(result.rawValue) for window \(id)") }
        return result == .success
    }

    // MARK: - Helpers

    private static func windowID(of element: AXUIElement) -> CGWindowID? {
        var id = CGWindowID()
        return _AXUIElementGetWindow(element, &id) == .success ? id : nil
    }

    private static func copyAttribute(_ name: String, from element: AXUIElement) -> AnyObject? {
        var value: AnyObject?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    private func stringAttribute(_ name: String) -> String? {
        Self.copyAttribute(name, from: element) as? String
    }

    private func pointAttribute(_ name: String) -> CGPoint? {
        guard let value = Self.axValue(Self.copyAttribute(name, from: element)) else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(value, .cgPoint, &point) ? point : nil
    }

    private func sizeAttribute(_ name: String) -> CGSize? {
        guard let value = Self.axValue(Self.copyAttribute(name, from: element)) else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(value, .cgSize, &size) ? size : nil
    }

    // CF types can't be conditionally cast in Swift; the type ID is the runtime check.
    private static func element(_ value: AnyObject?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private static func axValue(_ value: AnyObject?) -> AXValue? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXValue.self)
    }

    private func isAttributeSettable(_ name: String) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, name as CFString, &settable) == .success && settable.boolValue
    }
}

// One window-server snapshot: which process owns which window right now. Take one per operation
// and pass it along; the query lists every window on the system.
nonisolated struct WindowList: Sendable {
    let owners: [CGWindowID: pid_t]
    private let bundleIDs: [pid_t: String]

    init(owners: [CGWindowID: pid_t], bundleIDs: [pid_t: String]) {
        self.owners = owners
        self.bundleIDs = bundleIDs
    }

    // CGWindowListCreateDescriptionFromArray wants raw-pointer CFNumbers and silently returns nothing
    // otherwise, so we take the whole list and index it ourselves.
    static func current() -> WindowList {
        var owners: [CGWindowID: pid_t] = [:]
        if let info = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] {
            for entry in info {
                guard let id = entry[kCGWindowNumber as String] as? CGWindowID,
                      let pid = entry[kCGWindowOwnerPID as String] as? pid_t
                else { continue }
                owners[id] = pid
            }
        }
        var bundleIDs: [pid_t: String] = [:]
        for app in NSWorkspace.shared.runningApplications {
            if let bundleID = app.bundleIdentifier { bundleIDs[app.processIdentifier] = bundleID }
        }
        return WindowList(owners: owners, bundleIDs: bundleIDs)
    }

    // Window IDs start over after a restart, so a saved ID can come back as someone else's window.
    // It's only the same window if the same app still owns it.
    func contains(_ slot: WindowSlot) -> Bool {
        guard let pid = owners[slot.windowID] else { return false }
        return bundleIDs[pid] == slot.bundleID
    }

    var runningBundleIDs: Set<String> { Set(bundleIDs.values) }
}
