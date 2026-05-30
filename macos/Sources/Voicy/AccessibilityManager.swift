import AppKit
import ApplicationServices

// AccessibilityManager owns the Accessibility (AX) trust state for the app.
// Because the frontend is the properly-bundled process the user grants in
// System Settings, the AX check must run here - not in the Go backend helper,
// which has a different TCC identity.
final class AccessibilityManager {
    /// Called on the main queue whenever trust state is (re)checked.
    var onChange: ((Bool) -> Void)?

    private(set) var isTrusted: Bool = false
    private var timer: Timer?

    /// Prompts the user once (adds Voicy to the Accessibility list) and starts
    /// polling for the trust state.
    func start(prompt: Bool) {
        if prompt {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            isTrusted = AXIsProcessTrustedWithOptions(options)
        } else {
            isTrusted = AXIsProcessTrusted()
        }
        onChange?(isTrusted)

        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func refresh() {
        let trusted = AXIsProcessTrusted()
        if trusted != isTrusted {
            isTrusted = trusted
            onChange?(trusted)
        }
    }

    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    static func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }
}
