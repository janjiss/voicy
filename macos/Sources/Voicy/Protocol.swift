import Foundation

// Codable mirror of the Go internal/uiproto wire types. Keep field names in
// sync with internal/uiproto/uiproto.go.

struct Config: Codable, Equatable {
    var pushToTalkKey: String
    var whisperBinary: String
    var modelName: String
    var autoInsert: Bool
    var transformSelected: Bool

    static let empty = Config(
        pushToTalkKey: "right_option",
        whisperBinary: "",
        modelName: "ggml-large-v3-turbo-q5_0.bin",
        autoInsert: true,
        transformSelected: false
    )
}

struct HistoryEntry: Codable, Identifiable, Equatable {
    var at: String
    var transcript: String

    var id: String { at + transcript }
}

struct ViewState: Codable, Equatable {
    var state: String
    var config: Config
    var lastTranscript: String
    var lastInserted: String
    var lastError: String
    var history: [HistoryEntry]
    var updatedAt: String

    static let idle = ViewState(
        state: "idle",
        config: .empty,
        lastTranscript: "",
        lastInserted: "",
        lastError: "",
        history: [],
        updatedAt: ""
    )
}

struct Levels: Codable, Equatable {
    var current: Double
    var session: Double
}

struct Permissions: Codable, Equatable {
    var accessibility: Bool
    var microphone: Bool
}

struct ModelProgress: Codable, Equatable {
    var name: String
    var downloaded: Int64
    var total: Int64
    var done: Bool
    var error: String?
}

struct InsertText: Codable, Equatable {
    var text: String
}

// Command envelope written to the backend's stdin.

struct CommandPayload: Codable {
    var config: Config?
    var modelName: String?
}

struct Command: Codable {
    var type: String
    var payload: CommandPayload?

    static func simple(_ type: String) -> Command { Command(type: type, payload: nil) }
}

// Event decoding helpers. The wire envelope is {"type": ..., "payload": ...}
// with a type-specific payload, so we probe the type first.

struct TypeProbe: Codable {
    var type: String
}

struct EventEnvelope<Payload: Codable>: Codable {
    var type: String
    var payload: Payload
}

enum IncomingEvent {
    case state(ViewState)
    case levels(Levels)
    case permissions(Permissions)
    case modelProgress(ModelProgress)
    case insertText(String)

    static func decode(_ data: Data) -> IncomingEvent? {
        let decoder = JSONDecoder()
        guard let probe = try? decoder.decode(TypeProbe.self, from: data) else { return nil }
        switch probe.type {
        case "state":
            if let e = try? decoder.decode(EventEnvelope<ViewState>.self, from: data) { return .state(e.payload) }
        case "levels":
            if let e = try? decoder.decode(EventEnvelope<Levels>.self, from: data) { return .levels(e.payload) }
        case "permissions":
            if let e = try? decoder.decode(EventEnvelope<Permissions>.self, from: data) { return .permissions(e.payload) }
        case "modelProgress":
            if let e = try? decoder.decode(EventEnvelope<ModelProgress>.self, from: data) { return .modelProgress(e.payload) }
        case "insertText":
            if let e = try? decoder.decode(EventEnvelope<InsertText>.self, from: data) { return .insertText(e.payload.text) }
        default:
            return nil
        }
        return nil
    }
}

// Command type constants, mirroring internal/uiproto.
enum CommandType {
    static let beginRecording = "beginRecording"
    static let finishRecording = "finishRecording"
    static let quickTest = "quickTest"
    static let updateConfig = "updateConfig"
    static let downloadModel = "downloadModel"
    static let clearHistory = "clearHistory"
    static let openAccessibility = "openAccessibilitySettings"
    static let openMicrophone = "openMicrophoneSettings"
    static let shutdown = "shutdown"
}
