import AppKit
import SwiftUI

private let pushToTalkKeys = [
    "left_command", "right_command",
    "left_option", "right_option",
    "left_control", "right_control",
    "left_shift", "right_shift",
    "space", "fn"
]
private let modelNames = ["ggml-large-v3-turbo-q5_0.bin", "ggml-large-v3-turbo.bin"]

// SettingsView follows the macOS Human Interface Guidelines for settings windows:
// a TabView of toolbar tabs, each a grouped Form with sections, LabeledContent
// rows, and native controls.
struct SettingsView: View {
    @ObservedObject var appState: AppState
    let ipc: IPCClient
    @State private var recordingShortcutID: String?

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("General", systemImage: "gearshape") }
            transcriptionTab
                .tabItem { Label("Transcription", systemImage: "waveform") }
            permissionsTab
                .tabItem { Label("Permissions", systemImage: "lock.shield") }
            historyTab
                .tabItem { Label("History", systemImage: "clock") }
        }
        .frame(width: 500, height: 560)
    }

    // MARK: General

    private var generalTab: some View {
        Form {
            Section("Status") {
                LabeledContent("State") {
                    HStack(spacing: 6) {
                        Circle().fill(stateColor).frame(width: 8, height: 8)
                        Text(stateLabel)
                    }
                }
                LabeledContent("Microphone") {
                    ProgressView(value: min(max(appState.levels.current, 0), 1))
                        .frame(width: 160)
                }
                if !appState.view.lastError.isEmpty {
                    LabeledContent("Last error") {
                        Text(appState.view.lastError)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.trailing)
                    }
                }
            }

            Section("Dictation") {
                HStack {
                    Button {
                        ipc.beginRecording()
                    } label: { Label("Start", systemImage: "record.circle") }
                    Button {
                        ipc.finishRecording()
                    } label: { Label("Stop & Transcribe", systemImage: "stop.circle") }
                    Button {
                        ipc.quickTest()
                    } label: { Label("3-Second Test", systemImage: "play.circle") }
                }
            }

            Section {
                ForEach(appState.view.config.hotkeyMappings) { mapping in
                    hotkeyMappingRow(mapping)
                }
                Button {
                    addHotkeyMapping()
                } label: {
                    Label("Add Shortcut", systemImage: "plus")
                }
            } header: {
                Text("Shortcuts")
            } footer: {
                Text(keyHint).font(.callout).foregroundStyle(.secondary)
            }

            Section("Behavior") {
                Toggle("Auto-insert transcript into the active app", isOn: configBinding(\.autoInsert))
                Toggle("Copy produced text to clipboard", isOn: configBinding(\.copyToClipboard))
                Toggle("Pause and resume music while recording", isOn: configBinding(\.pauseMusic))
                Toggle("Use selected text as transform target (experimental)", isOn: configBinding(\.transformSelected))
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Transcription

    private var transcriptionTab: some View {
        Form {
            Section("Model") {
                Picker("Model", selection: configBinding(\.modelName)) {
                    ForEach(modelNames, id: \.self) { Text($0) }
                }
                TextField("Whisper binary", text: configBinding(\.whisperBinary), prompt: Text("Bundled"))
            }

            Section {
                LabeledContent("Download") {
                    Button("Download Model") {
                        ipc.downloadModel(appState.view.config.modelName)
                    }
                }
                if let progress = appState.modelProgress {
                    ProgressView(value: downloadFraction)
                    Text(downloadStatus(progress))
                        .font(.callout)
                        .foregroundStyle(progress.error != nil ? .red : .secondary)
                }
            } footer: {
                Text("Models download on demand from the whisper.cpp repository and are cached locally.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var downloadFraction: Double {
        guard let progress = appState.modelProgress, progress.total > 0 else { return 0 }
        return min(Double(progress.downloaded) / Double(progress.total), 1)
    }

    private func downloadStatus(_ progress: ModelProgress) -> String {
        if let err = progress.error, !err.isEmpty { return "Download failed: \(err)" }
        if progress.done { return "\(progress.name) is ready." }
        if progress.total > 0 {
            return String(format: "Downloading %@ - %.0f%%", progress.name, downloadFraction * 100)
        }
        return "Downloading \(progress.name)..."
    }

    // MARK: Permissions

    private var permissionsTab: some View {
        Form {
            Section {
                permissionRow(
                    title: "Accessibility",
                    granted: appState.permissions.accessibility,
                    detail: appState.permissions.accessibility ? "Granted" : "Required for hotkey + insertion",
                    button: "Open"
                ) { ipc.openAccessibilitySettings() }

                permissionRow(
                    title: "Microphone",
                    granted: appState.permissions.microphone,
                    detail: appState.permissions.microphone ? "Granted" : "Required for recording",
                    button: "Open"
                ) { ipc.openMicrophoneSettings() }
            } footer: {
                Text("Accessibility powers the global push-to-talk hotkey and pasting into other apps. After granting it for a freshly built Voicy, fully quit and relaunch.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func permissionRow(title: String, granted: Bool, detail: String, button: String, action: @escaping () -> Void) -> some View {
        LabeledContent {
            HStack(spacing: 10) {
                Text(detail).foregroundStyle(.secondary)
                Button(button, action: action)
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .foregroundStyle(granted ? Color.green : Color.orange)
                Text(title)
            }
        }
    }

    // MARK: History

    private var historyTab: some View {
        Form {
            Section {
                if appState.view.history.isEmpty {
                    Text("No transcripts yet. Hold your push-to-talk key, speak, and release to see them appear here.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(appState.view.history) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(entry.at).font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Button {
                                    copyToPasteboard(entry.transcript)
                                } label: { Image(systemName: "doc.on.doc") }
                                    .buttonStyle(.borderless)
                                    .help("Copy")
                            }
                            Text(entry.transcript)
                        }
                        .padding(.vertical, 2)
                    }
                }
            } header: {
                HStack {
                    Text("Recent Transcripts")
                    Spacer()
                    Button {
                        ipc.clearHistory()
                    } label: { Label("Clear", systemImage: "trash") }
                        .buttonStyle(.borderless)
                        .disabled(appState.view.history.isEmpty)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func copyToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    // MARK: Helpers

    private var keyHint: String {
        let mappings = appState.view.config.hotkeyMappings
        if mappings.contains(where: { $0.keys == "fn" }) {
            return "fn may not be observable on all keyboards. If push-to-talk doesn't fire, switch to right_option."
        }
        return "Long press records until release. Double tap starts recording; press the same shortcut once to stop."
    }

    private var stateColor: Color {
        switch appState.view.state {
        case "recording", "error": return .red
        case "transcribing": return .blue
        case "inserting": return .green
        default: return .secondary
        }
    }

    private var stateLabel: String {
        switch appState.view.state {
        case "recording": return "Listening"
        case "transcribing": return "Transcribing"
        case "inserting": return "Inserting"
        case "error": return "Error"
        default: return "Idle"
        }
    }

    private func configBinding<T>(_ keyPath: WritableKeyPath<Config, T>) -> Binding<T> {
        Binding(
            get: { appState.view.config[keyPath: keyPath] },
            set: { newValue in
                var config = appState.view.config
                config[keyPath: keyPath] = newValue
                ipc.updateConfig(config)
            }
        )
    }

    private func hotkeyMappingRow(_ mapping: HotkeyMapping) -> some View {
        HStack {
            Button {
                recordingShortcutID = mapping.id
            } label: {
                Label(shortcutButtonTitle(mapping), systemImage: recordingShortcutID == mapping.id ? "keyboard.badge.ellipsis" : "keyboard")
            }
            .keyboardShortcutCapture(isActive: recordingShortcutID == mapping.id) { keys in
                updateHotkeyMapping(id: mapping.id, keys: keys, mode: nil)
                recordingShortcutID = nil
            }

            Picker("Form", selection: hotkeyModeBinding(mapping.id)) {
                Text("Long press").tag("long_press")
                Text("Double tap").tag("double_tap")
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            Button {
                removeHotkeyMapping(mapping.id)
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .disabled(appState.view.config.hotkeyMappings.count <= 1)
        }
    }

    private func hotkeyModeBinding(_ id: String) -> Binding<String> {
        Binding(
            get: { appState.view.config.hotkeyMappings.first(where: { $0.id == id })?.mode ?? "long_press" },
            set: { updateHotkeyMapping(id: id, keys: nil, mode: $0) }
        )
    }

    private func addHotkeyMapping() {
        var config = appState.view.config
        let id = UUID().uuidString
        config.hotkeyMappings.append(HotkeyMapping(id: id, keys: "right_option+space", mode: "double_tap", label: "Right Option + Space"))
        ipc.updateConfig(config)
    }

    private func removeHotkeyMapping(_ id: String) {
        var config = appState.view.config
        config.hotkeyMappings.removeAll { $0.id == id }
        if config.hotkeyMappings.isEmpty {
            config.hotkeyMappings = [HotkeyMapping(id: "default", keys: "right_option", mode: "long_press", label: "Right Option")]
        }
        ipc.updateConfig(config)
    }

    private func updateHotkeyMapping(id: String, keys: String?, mode: String?) {
        var config = appState.view.config
        guard let index = config.hotkeyMappings.firstIndex(where: { $0.id == id }) else { return }
        if let keys {
            config.hotkeyMappings[index].keys = keys
            config.hotkeyMappings[index].label = keys
        }
        if let mode {
            config.hotkeyMappings[index].mode = mode
        }
        config.pushToTalkKey = config.hotkeyMappings.first?.keys ?? "right_option"
        config.recordingMode = config.hotkeyMappings.first?.mode == "double_tap" ? "toggle" : "hold"
        ipc.updateConfig(config)
    }

    private func shortcutButtonTitle(_ mapping: HotkeyMapping) -> String {
        recordingShortcutID == mapping.id ? "Press Shortcut" : mapping.keys
    }
}

private struct KeyboardShortcutCapture: NSViewRepresentable {
    let isActive: Bool
    let onCapture: (String) -> Void

    func makeNSView(context: Context) -> CaptureView {
        let view = CaptureView()
        view.onCapture = onCapture
        return view
    }

    func updateNSView(_ view: CaptureView, context: Context) {
        view.onCapture = onCapture
        view.isActive = isActive
        if isActive {
            DispatchQueue.main.async {
                view.window?.makeFirstResponder(view)
            }
        }
    }

    final class CaptureView: NSView {
        var onCapture: ((String) -> Void)?
        var isActive = false {
            didSet {
                if !isActive {
                    pendingCapture?.cancel()
                    pendingCapture = nil
                    heldKeys.removeAll()
                }
            }
        }
        private var heldKeys = Set<String>()
        private var pendingCapture: DispatchWorkItem?

        override var acceptsFirstResponder: Bool { true }

        override func keyDown(with event: NSEvent) {
            guard isActive else { return }
            pendingCapture?.cancel()
            pendingCapture = nil
            syncModifiers(from: event)
            if let key = regularKey(from: event) {
                heldKeys.insert(key)
            }
            if let combo = currentCombo(), !combo.isEmpty {
                onCapture?(combo)
            }
        }

        override func flagsChanged(with event: NSEvent) {
            guard isActive else { return }
            syncModifiers(from: event)
            guard isModifierPress(event), let combo = currentCombo(), !combo.isEmpty else {
                return
            }
            pendingCapture?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.onCapture?(combo)
            }
            pendingCapture = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
        }

        private func currentCombo() -> String? {
            let ordered = pushToTalkKeys.filter { heldKeys.contains($0) }
            return ordered.isEmpty ? nil : ordered.joined(separator: "+")
        }

        private func syncModifiers(from event: NSEvent) {
            updateModifier("left_command", right: "right_command", flag: .command, leftKeyCode: 55, rightKeyCode: 54, event: event)
            updateModifier("left_option", right: "right_option", flag: .option, leftKeyCode: 58, rightKeyCode: 61, event: event)
            updateModifier("left_control", right: "right_control", flag: .control, leftKeyCode: 59, rightKeyCode: 62, event: event)
            updateModifier("left_shift", right: "right_shift", flag: .shift, leftKeyCode: 56, rightKeyCode: 60, event: event)
            if event.modifierFlags.contains(.function) {
                heldKeys.insert("fn")
            } else {
                heldKeys.remove("fn")
            }
        }

        private func updateModifier(_ left: String, right: String, flag: NSEvent.ModifierFlags, leftKeyCode: UInt16, rightKeyCode: UInt16, event: NSEvent) {
            if event.modifierFlags.contains(flag) {
                if event.keyCode == leftKeyCode {
                    heldKeys.insert(left)
                } else if event.keyCode == rightKeyCode {
                    heldKeys.insert(right)
                } else if !heldKeys.contains(left) && !heldKeys.contains(right) {
                    heldKeys.insert(left)
                }
            } else {
                heldKeys.remove(left)
                heldKeys.remove(right)
            }
        }

        private func regularKey(from event: NSEvent) -> String? {
            switch event.keyCode {
            case 49: return "space"
            default: return nil
            }
        }

        private func isModifierPress(_ event: NSEvent) -> Bool {
            switch event.keyCode {
            case 55, 54:
                return event.modifierFlags.contains(.command)
            case 58, 61:
                return event.modifierFlags.contains(.option)
            case 59, 62:
                return event.modifierFlags.contains(.control)
            case 56, 60:
                return event.modifierFlags.contains(.shift)
            case 63:
                return event.modifierFlags.contains(.function)
            default:
                return false
            }
        }
    }
}

private extension View {
    func keyboardShortcutCapture(isActive: Bool, onCapture: @escaping (String) -> Void) -> some View {
        background(KeyboardShortcutCapture(isActive: isActive, onCapture: onCapture).frame(width: 0, height: 0))
    }
}
