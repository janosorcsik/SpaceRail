// What the app tells the user after it did something, refused something, or acted on its own.
// One sentence, in the words a colleague would use.
nonisolated enum Feedback: Equatable, Sendable {
    case added(app: String, workspace: String)
    case removed(app: String, workspace: String)
    case switched(workspace: String)
    case following(app: String, workspace: String)
    case launching(app: String)
    case returned(app: String, workspace: String)
    case refused(Refusal)
    case hint(String)

    enum Refusal: Equatable, Sendable {
        case noFocusedWindow
        case notAWindow
        case noPermission
    }

    var message: String {
        switch self {
        case let .added(app, workspace): "\(app) added to \(workspace)"
        case let .removed(app, workspace): "\(app) removed from \(workspace) — press again to undo"
        case let .switched(workspace): workspace
        case let .following(app, workspace): "Following \(app) to \(workspace)"
        case let .launching(app): "Opening \(app)…"
        case let .returned(app, workspace): "\(app) is back in \(workspace)"
        case .refused(.noFocusedWindow): "Nothing to add — no window is focused"
        case .refused(.notAWindow): "Can't add this — it's a dialog or panel, not a window"
        case .refused(.noPermission): "SpaceRail needs Accessibility access — see the menu bar icon"
        case let .hint(text): text
        }
    }

    var symbol: String {
        switch self {
        case .added: "plus.circle.fill"
        case .removed: "minus.circle.fill"
        case .switched: "square.grid.2x2.fill"
        case .following: "arrow.right.circle.fill"
        case .launching: "arrow.up.forward.app.fill"
        case .returned: "checkmark.circle.fill"
        case .refused: "exclamationmark.triangle.fill"
        case .hint: "lightbulb.fill"
        }
    }

    var isRefusal: Bool {
        if case .refused = self { return true }
        return false
    }

    // How long the line stays up. Refusals and hints need reading; confirmations only need noticing.
    var duration: Duration {
        switch self {
        case .refused: .seconds(3)
        case .hint: .seconds(8)
        case .removed: .seconds(2.5)
        default: .seconds(1.5)
        }
    }
}
