import Foundation

// Convenience command helpers layered on top of the raw IPC transport.
extension IPCClient {
    func beginRecording() { send(.simple(CommandType.beginRecording)) }
    func finishRecording() { send(.simple(CommandType.finishRecording)) }
    func quickTest() { send(.simple(CommandType.quickTest)) }
    func clearHistory() { send(.simple(CommandType.clearHistory)) }
    func openAccessibilitySettings() { send(.simple(CommandType.openAccessibility)) }
    func openMicrophoneSettings() { send(.simple(CommandType.openMicrophone)) }

    func updateConfig(_ config: Config) {
        send(Command(type: CommandType.updateConfig, payload: CommandPayload(config: config, modelName: nil)))
    }

    func downloadModel(_ name: String) {
        send(Command(type: CommandType.downloadModel, payload: CommandPayload(config: nil, modelName: name)))
    }
}
