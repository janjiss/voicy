import AppKit
import CoreGraphics

// TextInjector pastes transcribed text into the active app by placing it on the
// pasteboard and synthesizing Cmd+V. Synthetic input requires Accessibility,
// which the frontend holds. This is a Swift port of the Go internal/inject
// darwin path.
final class TextInjector {
    private let vKeyCode: CGKeyCode = 9 // "v"

    func insert(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Give the pasteboard a moment to settle before pasting.
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.12) { [weak self] in
            self?.postCommandKey(self?.vKeyCode ?? 9)
        }
    }

    private func postCommandKey(_ keyCode: CGKeyCode) {
        let source = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
