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

    // ⌃⌥⌘<n> / ⌃⌥⌘⇧<n> by position, if the position has a digit. Runs once per workspace per
    // defaults domain (a marker in UserDefaults), so a shortcut the user cleared on purpose stays
    // cleared, while a fresh install or a bundle-ID change still gets the defaults.
    static func installDefaultsIfNeeded(for workspace: Workspace, position: Int) {
        let marker = seededKey(workspace.id)
        guard !UserDefaults.standard.bool(forKey: marker) else { return }
        UserDefaults.standard.set(true, forKey: marker)
        guard position < digits.count else { return }

        let key = digits[position]
        if getShortcut(for: .switchTo(workspace.id)) == nil {
            setShortcut(.init(key, modifiers: Name.hyper), for: .switchTo(workspace.id))
        }
        if getShortcut(for: .toggle(workspace.id)) == nil {
            setShortcut(.init(key, modifiers: Name.hyper.union(.shift)), for: .toggle(workspace.id))
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
