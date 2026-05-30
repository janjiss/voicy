import AppKit
import Combine
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let appState = AppState()
    private let ipc = IPCClient()
    private var menuBar: MenuBarController?
    private let hud = HUDPanel()

    private let accessibility = AccessibilityManager()
    private let injector = TextInjector()
    private let hotkey = HotkeyTap(key: "right_option")

    private var settingsWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenuBar()
        setupIPC()
        setupAccessibilityAndHotkey()
        observeStateForHUD()
        observeLevelsForHUD()
        observeConfig()
        showSettingsWindow()
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkey.stop()
        accessibility.stop()
        ipc.stop()
    }

    // MARK: Wiring

    private func setupMenuBar() {
        let menuBar = MenuBarController()
        menuBar.onOpenSettings = { [weak self] in self?.showSettingsWindow() }
        menuBar.onStart = { [weak self] in self?.ipc.beginRecording() }
        menuBar.onStop = { [weak self] in self?.ipc.finishRecording() }
        menuBar.onQuit = { NSApp.terminate(nil) }
        self.menuBar = menuBar
    }

    private func setupIPC() {
        ipc.onEvent = { [weak self] event in
            guard let self else { return }
            if case let .insertText(text) = event {
                self.injector.insert(text)
                return
            }
            self.appState.apply(event)
        }
        ipc.onTerminate = {
            NSApp.terminate(nil)
        }
        do {
            try ipc.start()
        } catch {
            presentFatal("Could not start the Voicy backend: \(error.localizedDescription)")
        }
    }

    private func setupAccessibilityAndHotkey() {
        hotkey.onPress = { [weak self] in self?.ipc.beginRecording() }
        hotkey.onRelease = { [weak self] in self?.ipc.finishRecording() }

        accessibility.onChange = { [weak self] trusted in
            guard let self else { return }
            self.appState.permissions.accessibility = trusted
            if trusted {
                if !self.hotkey.isRunning {
                    self.hotkey.start()
                }
            } else {
                self.hotkey.stop()
            }
        }
        accessibility.start(prompt: true)
    }

    private func observeConfig() {
        appState.$view
            .map(\.config.pushToTalkKey)
            .removeDuplicates()
            .sink { [weak self] key in
                guard let self else { return }
                self.hotkey.setKey(key)
                // Rebind the tap so the new key takes effect immediately.
                if self.hotkey.isRunning {
                    self.hotkey.stop()
                }
                if self.accessibility.isTrusted {
                    self.hotkey.start()
                }
            }
            .store(in: &cancellables)
    }

    private func observeStateForHUD() {
        appState.$view
            .map(\.state)
            .removeDuplicates()
            .sink { [weak self] state in
                self?.updateHUD(for: state)
            }
            .store(in: &cancellables)
    }

    private func observeLevelsForHUD() {
        appState.$levels
            .map(\.current)
            .sink { [weak self] level in
                self?.hud.setLevel(level)
            }
            .store(in: &cancellables)
    }

    private func updateHUD(for state: String) {
        switch state {
        case "recording":
            hud.setMode(.listening)
        case "transcribing", "inserting":
            hud.setMode(.processing)
        case "error":
            let message = appState.view.lastError.isEmpty ? "Something went wrong" : truncate(appState.view.lastError, 80)
            hud.setMode(.error(message))
        default:
            hud.setMode(.idle)
        }
    }

    // MARK: Settings window

    private func showSettingsWindow() {
        if let window = settingsWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hosting = NSHostingController(rootView: SettingsView(appState: appState, ipc: ipc))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Voicy"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(NSSize(width: 500, height: 560))
        window.isReleasedWhenClosed = false
        window.center()
        settingsWindow = window

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func presentFatal(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Voicy"
        alert.informativeText = message
        alert.alertStyle = .critical
        alert.runModal()
        NSApp.terminate(nil)
    }

    private func truncate(_ value: String, _ limit: Int) -> String {
        value.count <= limit ? value : String(value.prefix(limit)) + "..."
    }
}
