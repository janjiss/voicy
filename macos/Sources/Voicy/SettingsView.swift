import AppKit
import SwiftUI

private let pushToTalkKeys = [
    "left_command", "right_command",
    "left_option", "right_option",
    "left_control", "right_control",
    "left_shift", "right_shift",
    "space", "fn"
]

// A selectable, downloadable model. Used for both transcription and LLM
// correction so the two settings panels share one control style. Keep names in
// sync with the Go internal/models registry.
struct ModelOption: Identifiable, Hashable {
    let name: String
    let title: String
    let detail: String
    var id: String { name }
}

private let transcriptionModelOptions = [
    ModelOption(
        name: "ggml-large-v3-turbo-q5_0.bin",
        title: "Large v3 Turbo (recommended)",
        detail: "~0.5 GB · quantized, faster and smaller"
    ),
    ModelOption(
        name: "ggml-large-v3-turbo.bin",
        title: "Large v3 Turbo",
        detail: "~1.6 GB · full precision, highest quality"
    ),
]

private let llmModelOptions = [
    ModelOption(
        name: "Llama-3.2-3B-Instruct-Q4_K_M.gguf",
        title: "Llama 3.2 3B (recommended)",
        detail: "~2.0 GB · fastest, lightest, broadest testing"
    ),
    ModelOption(
        name: "Qwen3-4B-Q4_K_M.gguf",
        title: "Qwen3 4B (most accurate)",
        detail: "~2.5 GB · best grammar/punctuation accuracy"
    ),
    ModelOption(
        name: "gemma-3-4b-it-Q4_K_M.gguf",
        title: "Gemma 3 4B (multilingual)",
        detail: "~2.5 GB · strongest across 140+ languages"
    ),
]

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
            aiFormattingTab
                .tabItem { Label("AI Formatting", systemImage: "sparkles") }
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
            modelControls(
                options: transcriptionModelOptions,
                selection: configBinding(\.modelName),
                binaryBinding: configBinding(\.whisperBinary),
                binaryLabel: "Whisper binary",
                downloadInfo: "Models download on demand and are cached locally on your Mac."
            )
        }
        .formStyle(.grouped)
    }

    // MARK: Shared model controls

    // modelControls renders the model picker, download button + progress, and
    // an advanced binary-path override. Both the Transcription and AI Formatting
    // tabs use it so the two panels stay visually identical.
    @ViewBuilder
    private func modelControls(
        options: [ModelOption],
        selection: Binding<String>,
        binaryBinding: Binding<String>,
        binaryLabel: String,
        downloadInfo: String,
        enabled: Bool = true
    ) -> some View {
        Section("Model") {
            Picker("Model", selection: selection) {
                ForEach(options) { option in
                    VStack(alignment: .leading) {
                        Text(option.title)
                        Text(option.detail).font(.caption).foregroundStyle(.secondary)
                    }
                    .tag(option.name)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            .disabled(!enabled)
        }

        let selected = selection.wrappedValue
        let isInstalled = appState.installedModels.contains(selected)
        // Only treat progress as belonging to this control when it's for the
        // exact model currently selected, so a transcription download never
        // shows under AI Formatting (or for a different model in the same tab).
        let active: ModelProgress? = appState.modelProgress.flatMap { $0.name == selected ? $0 : nil }

        Section {
            LabeledContent(isInstalled ? "Model" : "Download") {
                Button(isInstalled ? "Re-download" : "Download Model") {
                    ipc.downloadModel(selected)
                }
                .disabled(!enabled)
            }
            if let progress = active, let err = progress.error, !err.isEmpty {
                Text(downloadStatus(progress)).font(.callout).foregroundStyle(.red)
            } else if let progress = active, !progress.done {
                ProgressView(value: progress.total > 0 ? min(Double(progress.downloaded) / Double(progress.total), 1) : 0)
                Text(downloadStatus(progress)).font(.callout).foregroundStyle(.secondary)
            } else if isInstalled {
                Label("Downloaded", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.callout)
            }
        } footer: {
            Text(downloadInfo)
                .font(.callout)
                .foregroundStyle(.secondary)
        }

        Section("Advanced") {
            TextField(binaryLabel, text: binaryBinding, prompt: Text("Bundled"))
                .disabled(!enabled)
        }
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

    // MARK: AI Formatting

    private var aiFormattingTab: some View {
        Form {
            Section {
                Toggle("Enable AI text correction", isOn: configBinding(\.formatWithLLM))
            } footer: {
                Text("Runs a local model to fix punctuation, capitalization, and remove filler words from your dictation. Everything stays on your Mac.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            modelControls(
                options: llmModelOptions,
                selection: configBinding(\.llmModelName),
                binaryBinding: configBinding(\.llmBinary),
                binaryLabel: "llama-cli binary",
                downloadInfo: "The selected model downloads on demand and is cached locally on your Mac.",
                enabled: appState.view.config.formatWithLLM
            )
        }
        .formStyle(.grouped)
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
