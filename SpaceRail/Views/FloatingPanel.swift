import SwiftUI

final class FloatingPanel: NSPanel {
    enum Placement {
        // Slightly above centre, like the system volume/brightness HUD.
        case center
        // Just above the Dock, where a one-line confirmation sits without covering work.
        case bottom
    }

    private let hostingView: NSHostingView<AnyView>
    private let placement: Placement
    private weak var targetScreen: NSScreen?
    // A fade-out only orders the panel out if nothing showed it again in the meantime.
    private var showGeneration = 0

    init(placement: Placement = .center, view: () -> some View) {
        self.placement = placement
        hostingView = NSHostingView(rootView: AnyView(view()))
        hostingView.sizingOptions = [.preferredContentSize]

        super.init(
            contentRect: NSRect(),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )

        isFloatingPanel = true
        level = .statusBar
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        setAccessibilitySubrole(.unknown)

        contentView = hostingView

        // Content drives the size (preferredContentSize); keep it centred whenever that changes.
        NotificationCenter.default.addObserver(self, selector: #selector(recenter), name: NSWindow.didResizeNotification, object: self)
    }

    // Opened by a hotkey many times a day: no entrance animation, it would only read as latency.
    // `screen` is where the user is working; it stays the anchor while the content resizes.
    func showPanel(on screen: NSScreen? = nil) {
        if let screen { targetScreen = screen }
        showGeneration += 1
        // A zero-length animation replaces a fade-out still in flight; setting alphaValue directly
        // would let the fade run on to 0 and leave an invisible panel on screen.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            animator().alphaValue = 1
        }
        if !isVisible { orderFrontRegardless() }
        hostingView.layoutSubtreeIfNeeded()
        recenter()
    }

    @objc private func recenter() {
        guard let screen = (targetScreen ?? NSScreen.main)?.visibleFrame else { return }
        let size = frame.size
        let y: CGFloat = switch placement {
        case .center: screen.midY - size.height / 2 + screen.height * 0.08
        case .bottom: screen.minY + 48
        }
        let origin = NSPoint(x: (screen.midX - size.width / 2).rounded(), y: y.rounded())
        if frame.origin != origin { setFrameOrigin(origin) }
    }

    // Usually triggered by the auto-hide timer, not the user, so a short fade keeps it from
    // vanishing abruptly. Exit is faster than any entrance would be, and ease-out, not in-out.
    func hidePanel() {
        guard isVisible else { return }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            orderOut(nil)
            return
        }
        let generation = showGeneration
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.showGeneration == generation else { return }
                self.orderOut(nil)
            }
        })
    }
}
