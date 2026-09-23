import ApplicationServices

enum Permissions {
    static var isAccessibilityTrusted: Bool {
        AXIsProcessTrusted()
    }

    // With prompt: true the system shows its own dialog and adds the app to the Accessibility list.
    @discardableResult
    static func ensureAccessibility(prompt: Bool) -> Bool {
        // The value of kAXTrustedCheckOptionPrompt, which Swift 6 won't read: it's an imported global var.
        let key = "AXTrustedCheckOptionPrompt"
        return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
    }
}
