// Package uiproto defines the newline-delimited JSON wire protocol that the Go
// backend and native frontends use to communicate. The protocol is the
// cross-platform adapter seam: any frontend (macOS Swift today, Linux later)
// that speaks this protocol can drive the backend.
//
// The backend writes Event values to stdout, one JSON object per line. The
// frontend writes Command values to stdin, one JSON object per line.
package uiproto

// Event types emitted by the backend (one per line on stdout).
const (
	EventState         = "state"
	EventLevels        = "levels"
	EventPermissions   = "permissions"
	EventModelProgress = "modelProgress"
	EventCopyText      = "copyText"
	// EventInsertText asks the native frontend to inject text into the active
	// app. Injection requires Accessibility, which on macOS is held by the
	// frontend (the process the user actually grants), not the backend helper.
	EventInsertText = "insertText"
)

// Command types accepted by the backend (one per line on stdin).
const (
	CommandBeginRecording    = "beginRecording"
	CommandFinishRecording   = "finishRecording"
	CommandQuickTest         = "quickTest"
	CommandUpdateConfig      = "updateConfig"
	CommandDownloadModel     = "downloadModel"
	CommandClearHistory      = "clearHistory"
	CommandOpenAccessibility = "openAccessibilitySettings"
	CommandOpenMicrophone    = "openMicrophoneSettings"
	CommandShutdown          = "shutdown"
)

// Event is the envelope written to stdout. Payload holds the type-specific body.
type Event struct {
	Type    string      `json:"type"`
	Payload interface{} `json:"payload,omitempty"`
}

// Command is the envelope read from stdin. Payload is decoded lazily based on
// Type so the server can dispatch without a fixed schema.
type Command struct {
	Type    string         `json:"type"`
	Payload CommandPayload `json:"payload,omitempty"`
}

// CommandPayload carries the union of fields used by any command. Unused fields
// are simply zero. This keeps the wire format flat and easy to mirror in Swift.
type CommandPayload struct {
	Config    *Config `json:"config,omitempty"`
	ModelName string  `json:"modelName,omitempty"`
}

// Config mirrors internal/app.Config on the wire.
type Config struct {
	PushToTalkKey     string          `json:"pushToTalkKey"`
	HotkeyMappings    []HotkeyMapping `json:"hotkeyMappings"`
	WhisperBinary     string          `json:"whisperBinary"`
	ModelName         string          `json:"modelName"`
	AutoInsert        bool            `json:"autoInsert"`
	TransformSelected bool            `json:"transformSelected"`
	RecordingMode     string          `json:"recordingMode"`
	CopyToClipboard   bool            `json:"copyToClipboard"`
	PauseMusic        bool            `json:"pauseMusic"`
}

type HotkeyMapping struct {
	ID    string `json:"id"`
	Keys  string `json:"keys"`
	Mode  string `json:"mode"`
	Label string `json:"label"`
}

// HistoryEntry mirrors internal/app.HistoryEntry on the wire.
type HistoryEntry struct {
	At         string `json:"at"`
	Transcript string `json:"transcript"`
}

// ViewState is the full UI snapshot carried by an EventState event.
type ViewState struct {
	State          string         `json:"state"`
	Config         Config         `json:"config"`
	LastTranscript string         `json:"lastTranscript"`
	LastInserted   string         `json:"lastInserted"`
	LastError      string         `json:"lastError"`
	History        []HistoryEntry `json:"history"`
	UpdatedAt      string         `json:"updatedAt"`
}

// Levels is the body of an EventLevels event.
type Levels struct {
	Current float64 `json:"current"`
	Session float64 `json:"session"`
}

// Permissions is the body of an EventPermissions event.
type Permissions struct {
	Accessibility bool `json:"accessibility"`
	Microphone    bool `json:"microphone"`
}

// InsertText is the body of an EventInsertText event.
type InsertText struct {
	Text string `json:"text"`
}

// CopyText is the body of an EventCopyText event.
type CopyText struct {
	Text string `json:"text"`
}

// ModelProgress is the body of an EventModelProgress event.
type ModelProgress struct {
	Name       string `json:"name"`
	Downloaded int64  `json:"downloaded"`
	Total      int64  `json:"total"`
	Done       bool   `json:"done"`
	Error      string `json:"error,omitempty"`
}
