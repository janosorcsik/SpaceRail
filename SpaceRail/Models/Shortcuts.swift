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

    // Called once when a workspace is created: ⌃⌥⌘<n> / ⌃⌥⌘⇧<n> by position, if the position has a digit.
    static func installDefaults(for workspace: Workspace, position: Int) {
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
    }
}
