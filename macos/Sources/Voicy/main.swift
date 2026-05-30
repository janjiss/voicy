import AppKit

// Voicy is a menu-bar app: it lives in the status bar with no Dock icon. The
// .accessory activation policy is the runtime equivalent of LSUIElement and
// also applies when launched via `swift run` during development.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
