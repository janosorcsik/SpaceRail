import ApplicationServices

enum Permissions {
    static var isAccessibilityTrusted: Bool {
        AXIsProcessTrusted()
    }

    // With prompt: true the system shows its own dialog and adds the app to the Accessibility list.
    @discardableResult
    static func ensureAccessibility(prompt: Bool) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
    }
}
