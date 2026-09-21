import SwiftUI

final class FloatingPanel: NSPanel {
    private let hostingView: NSHostingView<AnyView>

    init(view: () -> some View) {
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
    func showPanel() {
        alphaValue = 1
        if !isVisible { orderFrontRegardless() }
        hostingView.layoutSubtreeIfNeeded()
        recenter()
    }

    // Slightly above centre reads better than dead centre, like the system volume/brightness HUD.
    @objc private func recenter() {
        guard let screen = NSScreen.main?.visibleFrame else { return }
        let size = frame.size
        let origin = NSPoint(
            x: (screen.midX - size.width / 2).rounded(),
            y: (screen.midY - size.height / 2 + screen.height * 0.08).rounded()
        )
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
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.alphaValue == 0 else { return }
                self.orderOut(nil)
            }
        })
    }
}
