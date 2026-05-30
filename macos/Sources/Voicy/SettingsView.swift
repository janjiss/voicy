import AppKit
import SwiftUI

private let pushToTalkKeys = ["right_option", "left_option", "space", "right_control", "left_control", "fn"]
private let modelNames = ["ggml-large-v3-turbo-q5_0.bin", "ggml-large-v3-turbo.bin"]

// SettingsView follows the macOS Human Interface Guidelines for settings windows:
// a TabView of toolbar tabs, each a grouped Form with sections, LabeledContent
// rows, and native controls.
struct SettingsView: View {
    @ObservedObject var appState: AppState
    let ipc: IPCClient

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
                Picker("Push-to-talk key", selection: configBinding(\.pushToTalkKey)) {
                    ForEach(pushToTalkKeys, id: \.self) { Text($0) }
                }
            } header: {
                Text("Push-To-Talk")
            } footer: {
                Text(keyHint).font(.callout).foregroundStyle(.secondary)
            }

            Section("Behavior") {
                Toggle("Auto-insert transcript into the active app", isOn: configBinding(\.autoInsert))
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
        switch appState.view.config.pushToTalkKey {
        case "fn":
            return "fn may not be observable on all keyboards. If push-to-talk doesn't fire, switch to right_option."
        case "space":
            return "Holding space outside text fields will trigger dictation. Avoid this if you type often."
        default:
            return "Hold \(appState.view.config.pushToTalkKey) to dictate. Release it to transcribe and insert."
        }
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
}
