import AppKit

// AX geometry has its origin at the top-left of the primary display with y growing down; AppKit's
// is bottom-left with y growing up. Everything here speaks AX unless it says otherwise.
enum Screens {
    // Enough of a window must stay on a display to grab its title bar and drag it back.
    private static let minimumVisible = CGSize(width: 100, height: 40)

    static func visibleFrames() -> [CGRect] {
        NSScreen.screens.map { toAX($0.visibleFrame) }
    }

    static func toAX(_ rect: CGRect) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.maxY ?? 0
        return CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    // A saved frame that no longer lands on any display (one was unplugged, or arranged differently)
    // goes to the main display: same size if it fits, centred.
    static func placeOnScreen(_ frame: CGRect, screens: [CGRect] = visibleFrames()) -> CGRect {
        guard let main = screens.first else { return frame }
        let needed = CGSize(width: min(minimumVisible.width, frame.width), height: min(minimumVisible.height, frame.height))
        let reachable = screens.contains { screen in
            let overlap = screen.intersection(frame)
            return !overlap.isNull && overlap.width >= needed.width && overlap.height >= needed.height
        }
        if reachable { return frame }

        let size = CGSize(width: min(frame.width, main.width), height: min(frame.height, main.height))
        return CGRect(
            x: (main.midX - size.width / 2).rounded(),
            y: (main.midY - size.height / 2).rounded(),
            width: size.width,
            height: size.height
        )
    }

    // The display the user is working on: the one holding most of the focused window, else the one
    // under the pointer.
    static func active() -> NSScreen? {
        if let app = NSWorkspace.shared.frontmostApplication,
           let frame = AXWindow.focusedWindow(of: app.processIdentifier)?.frame {
            let best = NSScreen.screens
                .map { ($0, area(toAX($0.frame).intersection(frame))) }
                .max { $0.1 < $1.1 }
            if let best, best.1 > 0 { return best.0 }
        }
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
    }

    private static func area(_ rect: CGRect) -> CGFloat {
        rect.isNull ? 0 : rect.width * rect.height
    }
}
