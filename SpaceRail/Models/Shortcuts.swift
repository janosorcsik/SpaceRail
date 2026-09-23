import AppKit
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let hyper: NSEvent.ModifierFlags = [.control, .option, .command]

    static func switchTo(_ workspaceID: Int) -> Self {
        Self("switch-\(workspaceID)")
    }

    static func toggle(_ workspaceID: Int) -> Self {
        Self("toggle-\(workspaceID)")
    }

    // A letter, not a digit: on non-US layouts (e.g. Hungarian) the "0" position is a different key.
    static let showHUD = Self("show-hud", initial: .init(.h, modifiers: hyper))
}

extension KeyboardShortcuts {
    private static let digits: [Key] = [.one, .two, .three, .four, .five, .six, .seven, .eight, .nine]

    // ⌃⌥⌘<n> / ⌃⌥⌘⇧<n>: the digit of the workspace's position, or, when another workspace already
    // uses that one (after a removal the positions shift), the first digit nobody uses. Runs once
    // per workspace per defaults domain (a marker in UserDefaults), so a shortcut the user cleared on
    // purpose stays cleared, while a fresh install or a bundle-ID change still gets the defaults.
    static func installDefaultsIfNeeded(for workspace: Workspace, among workspaces: [Workspace]) {
        let marker = seededKey(workspace.id)
        guard !UserDefaults.standard.bool(forKey: marker) else { return }
        UserDefaults.standard.set(true, forKey: marker)

        let others = workspaces.map(\.id).filter { $0 != workspace.id }
        let taken = Set(others.flatMap { [getShortcut(for: .switchTo($0)), getShortcut(for: .toggle($0))] }.compactMap(\.self))
        let position = workspaces.firstIndex { $0.id == workspace.id } ?? workspaces.count
        guard let key = defaultKey(position: position, taken: taken) else { return }

        if getShortcut(for: .switchTo(workspace.id)) == nil {
            setShortcut(.init(key, modifiers: Name.hyper), for: .switchTo(workspace.id))
        }
        if getShortcut(for: .toggle(workspace.id)) == nil {
            setShortcut(.init(key, modifiers: Name.hyper.union(.shift)), for: .toggle(workspace.id))
        }
    }

    static func defaultKey(position: Int, taken: Set<Shortcut>) -> Key? {
        let candidates = (position < digits.count ? [digits[position]] : []) + digits
        return candidates.first { key in
            !taken.contains(.init(key, modifiers: Name.hyper)) && !taken.contains(.init(key, modifiers: Name.hyper.union(.shift)))
        }
    }

    static func forget(workspaceID: Int) {
        reset(.switchTo(workspaceID), .toggle(workspaceID))
        UserDefaults.standard.removeObject(forKey: seededKey(workspaceID))
    }

    private static func seededKey(_ workspaceID: Int) -> String {
        "shortcutsSeeded-\(workspaceID)"
    }
}
