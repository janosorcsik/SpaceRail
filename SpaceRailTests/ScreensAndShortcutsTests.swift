import AppKit
import KeyboardShortcuts
import Testing

@Suite struct PlacingOnScreen {
    // Main display 1512×949 under a 33 pt menu bar; a second one to its right.
    let main = CGRect(x: 0, y: 33, width: 1512, height: 949)
    let external = CGRect(x: 1512, y: 0, width: 2560, height: 1415)

    @Test func frameOnADisplayIsKept() {
        let frame = CGRect(x: 2000, y: 100, width: 800, height: 600)
        #expect(Screens.placeOnScreen(frame, screens: [main, external]) == frame)
    }

    @Test func frameOnAnUnpluggedDisplayMovesToMain() {
        let frame = CGRect(x: 2000, y: 100, width: 800, height: 600)
        let placed = Screens.placeOnScreen(frame, screens: [main])
        #expect(placed.size == frame.size)
        #expect(main.contains(placed))
    }

    @Test func oversizedFrameIsShrunkToFit() {
        let frame = CGRect(x: 3000, y: 0, width: 2400, height: 1400)
        let placed = Screens.placeOnScreen(frame, screens: [main])
        #expect(placed.size == main.size)
    }

    @Test func slightlyOffscreenButGrabbableIsKept() {
        let frame = CGRect(x: 1400, y: 100, width: 800, height: 600)
        #expect(Screens.placeOnScreen(frame, screens: [main]) == frame)
    }
}

@Suite struct DefaultShortcuts {
    let hyper = KeyboardShortcuts.Name.hyper

    @Test func positionDigitWhenFree() {
        #expect(KeyboardShortcuts.defaultKey(position: 2, taken: []) == .three)
    }

    // Workspaces 1, 2, 3 with ⌃⌥⌘1–3; remove the second, add one: it's third, but 3 is taken.
    @Test func firstFreeDigitAfterARemoval() {
        let taken: Set<KeyboardShortcuts.Shortcut> = [
            .init(.one, modifiers: hyper), .init(.one, modifiers: hyper.union(.shift)),
            .init(.three, modifiers: hyper), .init(.three, modifiers: hyper.union(.shift)),
        ]
        #expect(KeyboardShortcuts.defaultKey(position: 2, taken: taken) == .two)
    }

    @Test func noDigitLeft() {
        let digits: [KeyboardShortcuts.Key] = [.one, .two, .three, .four, .five, .six, .seven, .eight, .nine]
        let taken = Set(digits.map { KeyboardShortcuts.Shortcut($0, modifiers: hyper) })
        #expect(KeyboardShortcuts.defaultKey(position: 0, taken: taken) == nil)
    }
}
