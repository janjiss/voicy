import AppKit

// MenuBarController owns the status-bar item and its menu, replacing the old
// Fyne system tray.
final class MenuBarController {
    private let statusItem: NSStatusItem

    var onOpenSettings: (() -> Void)?
    var onStart: (() -> Void)?
    var onStop: (() -> Void)?
    var onQuit: (() -> Void)?

    init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Voicy")
            button.image?.isTemplate = true
        }
        statusItem.menu = buildMenu()
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(item("Open Voicy", #selector(openSettings)))
        menu.addItem(.separator())
        menu.addItem(item("Start Recording", #selector(start)))
        menu.addItem(item("Stop & Transcribe", #selector(stop)))
        menu.addItem(.separator())
        menu.addItem(item("Quit Voicy", #selector(quit)))
        return menu
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: "")
        menuItem.target = self
        return menuItem
    }

    @objc private func openSettings() { onOpenSettings?() }
    @objc private func start() { onStart?() }
    @objc private func stop() { onStop?() }
    @objc private func quit() { onQuit?() }
}
