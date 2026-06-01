package app

import (
	"context"
	"errors"
	"fmt"
	"os"
	"sync"
	"time"
)

type State string

const (
	StateIdle         State = "idle"
	StateRecording    State = "recording"
	StateTranscribing State = "transcribing"
	StateInserting    State = "inserting"
	StateError        State = "error"
)

type Config struct {
	PushToTalkKey     string
	HotkeyMappings    []HotkeyMapping
	WhisperBinary     string
	ModelName         string
	AutoInsert        bool
	TransformSelected bool
	RecordingMode     string
	CopyToClipboard   bool
	PauseMusic        bool
	// FormatWithLLM enables local LLM post-formatting of dictated text
	// (punctuation, casing, removing filler words) and LLM-driven edits.
	FormatWithLLM bool
	// LLMModelName selects which downloaded GGUF correction model to use.
	LLMModelName string
	// LLMBinary optionally overrides the llama.cpp sidecar binary path.
	LLMBinary string
}

type HotkeyMapping struct {
	ID    string
	Keys  string
	Mode  string
	Label string
}

type Snapshot struct {
	State          State
	Config         Config
	LastTranscript string
	LastInserted   string
	LastError      string
	AudioPath      string
	UpdatedAt      time.Time
	History        []HistoryEntry
}

type HistoryEntry struct {
	At         time.Time
	Transcript string
}

const maxHistory = 10

// minRecordingDuration guards against accidental quick taps of the push-to-talk
// key. Anything shorter is treated as a silent cancel rather than an error.
const minRecordingDuration = 300 * time.Millisecond

// silenceRMSThreshold is the minimum root-mean-square amplitude (0.0 to 1.0) a
// recording must reach to be worth transcribing. Below it the clip is treated
// as silence and skipped, which prevents Whisper from hallucinating words like
// "you" or "Thank you." on empty audio.
const silenceRMSThreshold = 0.008

type Recorder interface {
	Start(context.Context) error
	Stop(context.Context) (string, error)
	IsRecording() bool
}

type LevelReader interface {
	CurrentPeak() float64
	SessionPeak() float64
}

type Transcriber interface {
	Transcribe(context.Context, string) (string, error)
}

type TextInjector interface {
	InsertText(context.Context, string) error
}

type ClipboardWriter interface {
	CopyText(context.Context, string) error
}

type SelectionReader interface {
	SelectedText(context.Context) (string, error)
}

type Transformer interface {
	CleanupTranscript(string) string
	Transform(context.Context, string, string) (string, error)
}

type HotkeyService interface {
	Start(context.Context, HotkeyCallbacks) error
	Stop() error
}

type HotkeyCallbacks struct {
	OnPress   func()
	OnRelease func()
}

type Services struct {
	Recorder    Recorder
	Transcriber Transcriber
	Injector    TextInjector
	Selection   SelectionReader
	Transformer Transformer
	Hotkey      HotkeyService
	Clipboard   ClipboardWriter
}

type Controller struct {
	services Services

	mu          sync.Mutex
	config      Config
	snapshot    Snapshot
	subscribers map[chan Snapshot]struct{}
	recordStart time.Time
}

func NewController(config Config, services Services) *Controller {
	now := time.Now()
	return &Controller{
		services: services,
		config:   config,
		snapshot: Snapshot{
			State:     StateIdle,
			Config:    config,
			UpdatedAt: now,
		},
		subscribers: make(map[chan Snapshot]struct{}),
	}
}

func (c *Controller) Start(ctx context.Context) error {
	if c.services.Hotkey == nil {
		return nil
	}

	return c.services.Hotkey.Start(ctx, HotkeyCallbacks{
		OnPress: func() {
			if err := c.BeginRecording(ctx); err != nil {
				c.fail(err)
			}
		},
		OnRelease: func() {
			go c.FinishRecording(ctx)
		},
	})
}

func (c *Controller) Shutdown() error {
	if c.services.Hotkey != nil {
		return c.services.Hotkey.Stop()
	}
	return nil
}

func (c *Controller) ReportError(err error) {
	if err != nil {
		c.fail(err)
	}
}

func (c *Controller) Subscribe(ctx context.Context) <-chan Snapshot {
	ch := make(chan Snapshot, 8)

	c.mu.Lock()
	c.subscribers[ch] = struct{}{}
	ch <- c.snapshot
	c.mu.Unlock()

	go func() {
		<-ctx.Done()
		c.mu.Lock()
		delete(c.subscribers, ch)
		close(ch)
		c.mu.Unlock()
	}()

	return ch
}

func (c *Controller) Snapshot() Snapshot {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.snapshot
}

// AudioLevel returns the current and session peak amplitudes between 0.0 and
// 1.0. Returns zero for both values if the recorder does not support metering.
func (c *Controller) AudioLevel() (current, session float64) {
	reader, ok := c.services.Recorder.(LevelReader)
	if !ok {
		return 0, 0
	}
	return reader.CurrentPeak(), reader.SessionPeak()
}

func (c *Controller) UpdateConfig(config Config) {
	c.mu.Lock()
	c.config = config
	c.snapshot.Config = config
	c.snapshot.UpdatedAt = time.Now()
	snapshot := c.snapshot
	c.mu.Unlock()

	if configurable, ok := c.services.Hotkey.(interface{ SetKey(string) }); ok {
		configurable.SetKey(config.PushToTalkKey)
	}

	c.broadcast(snapshot)
}

func (c *Controller) BeginRecording(ctx context.Context) error {
	if c.services.Recorder == nil {
		return errors.New("audio recorder is not configured")
	}

	c.mu.Lock()
	if c.snapshot.State == StateRecording || c.snapshot.State == StateTranscribing || c.snapshot.State == StateInserting {
		c.mu.Unlock()
		return nil
	}
	c.snapshot.State = StateRecording
	c.snapshot.LastError = ""
	c.snapshot.AudioPath = ""
	c.snapshot.UpdatedAt = time.Now()
	c.recordStart = time.Now()
	snapshot := c.snapshot
	c.mu.Unlock()
	c.broadcast(snapshot)

	if err := c.services.Recorder.Start(ctx); err != nil {
		c.fail(fmt.Errorf("start recording: %w", err))
		return err
	}

	return nil
}

func (c *Controller) FinishRecording(ctx context.Context) {
	if c.services.Recorder == nil {
		c.fail(errors.New("audio recorder is not configured"))
		return
	}

	c.mu.Lock()
	if c.snapshot.State != StateRecording {
		c.mu.Unlock()
		return
	}
	start := c.recordStart
	c.snapshot.State = StateTranscribing
	c.snapshot.UpdatedAt = time.Now()
	snapshot := c.snapshot
	c.mu.Unlock()
	c.broadcast(snapshot)

	elapsed := time.Since(start)
	audioPath, err := c.services.Recorder.Stop(ctx)

	// A quick tap captures little or no audio. Treat it as a silent cancel
	// instead of surfacing an error to the user.
	if elapsed < minRecordingDuration {
		if err == nil {
			os.Remove(audioPath)
		}
		c.setState(StateIdle)
		return
	}

	if err != nil {
		c.fail(fmt.Errorf("stop recording: %w", err))
		return
	}
	defer os.Remove(audioPath)

	// Skip transcription for effectively silent recordings to avoid Whisper
	// hallucinating words on empty audio.
	if reader, ok := c.services.Recorder.(interface{ SessionRMS() float64 }); ok {
		if reader.SessionRMS() < silenceRMSThreshold {
			c.setState(StateIdle)
			return
		}
	}

	c.mu.Lock()
	c.snapshot.AudioPath = audioPath
	snapshot = c.snapshot
	c.mu.Unlock()
	c.broadcast(snapshot)

	c.processAudio(ctx, audioPath)
}

func (c *Controller) TranscribeFile(ctx context.Context, audioPath string) {
	c.setState(StateTranscribing)
	c.processAudio(ctx, audioPath)
}

func (c *Controller) processAudio(ctx context.Context, audioPath string) {
	if c.services.Transcriber == nil {
		c.fail(errors.New("transcriber is not configured"))
		return
	}

	c.mu.Lock()
	config := c.config
	c.mu.Unlock()
	if configurable, ok := c.services.Transcriber.(interface {
		SetBinaryPath(string)
		SetModelName(string)
	}); ok {
		configurable.SetBinaryPath(config.WhisperBinary)
		configurable.SetModelName(config.ModelName)
	}

	transcript, err := c.services.Transcriber.Transcribe(ctx, audioPath)
	if err != nil {
		c.fail(fmt.Errorf("transcribe audio: %w", err))
		return
	}
	if c.services.Transformer != nil {
		transcript = c.services.Transformer.CleanupTranscript(transcript)

		// Push current LLM config onto the transformer so runtime config
		// changes (enable toggle, selected model) take effect immediately.
		if configurable, ok := c.services.Transformer.(interface {
			SetLLM(enabled bool, modelName, binary string)
		}); ok {
			configurable.SetLLM(config.FormatWithLLM, config.LLMModelName, config.LLMBinary)
		}

		// Optional LLM post-formatting. Formatting is a nicety, not a
		// correctness requirement, so a failure falls back to the cleaned
		// transcript rather than surfacing an error to the user.
		if config.FormatWithLLM {
			if formatter, ok := c.services.Transformer.(interface {
				Format(context.Context, string) (string, error)
			}); ok {
				if formatted, ferr := formatter.Format(ctx, transcript); ferr == nil {
					if formatted = c.services.Transformer.CleanupTranscript(formatted); formatted != "" {
						transcript = formatted
					}
				}
			}
		}
	}
	if transcript == "" {
		// No speech recognized: nothing to insert, so quietly return to idle
		// rather than reporting an error.
		c.setState(StateIdle)
		return
	}

	c.mu.Lock()
	c.snapshot.LastTranscript = transcript
	c.snapshot.History = prependCapped(c.snapshot.History, HistoryEntry{At: time.Now(), Transcript: transcript}, maxHistory)
	c.snapshot.UpdatedAt = time.Now()
	snapshot := c.snapshot
	c.mu.Unlock()
	c.broadcast(snapshot)

	textToInsert := transcript
	if config.TransformSelected && c.services.Selection != nil && c.services.Transformer != nil {
		selected, err := c.services.Selection.SelectedText(ctx)
		if err == nil && selected != "" {
			transformed, err := c.services.Transformer.Transform(ctx, selected, transcript)
			if err != nil {
				c.fail(fmt.Errorf("transform selected text: %w", err))
				return
			}
			textToInsert = transformed
		}
	}

	if config.AutoInsert && c.services.Injector != nil {
		c.setState(StateInserting)
		if err := c.services.Injector.InsertText(ctx, textToInsert); err != nil {
			c.fail(fmt.Errorf("insert text: %w", err))
			return
		}
	}
	if config.CopyToClipboard && c.services.Clipboard != nil {
		if err := c.services.Clipboard.CopyText(ctx, textToInsert); err != nil {
			c.fail(fmt.Errorf("copy text: %w", err))
			return
		}
	}

	c.mu.Lock()
	c.snapshot.State = StateIdle
	c.snapshot.LastInserted = textToInsert
	c.snapshot.LastError = ""
	c.snapshot.UpdatedAt = time.Now()
	snapshot = c.snapshot
	c.mu.Unlock()
	c.broadcast(snapshot)
}

func (c *Controller) setState(state State) {
	c.mu.Lock()
	c.snapshot.State = state
	c.snapshot.LastError = ""
	c.snapshot.UpdatedAt = time.Now()
	snapshot := c.snapshot
	c.mu.Unlock()
	c.broadcast(snapshot)
}

func (c *Controller) fail(err error) {
	c.mu.Lock()
	c.snapshot.State = StateError
	c.snapshot.LastError = err.Error()
	c.snapshot.UpdatedAt = time.Now()
	snapshot := c.snapshot
	c.mu.Unlock()
	c.broadcast(snapshot)
}

func (c *Controller) ClearHistory() {
	c.mu.Lock()
	c.snapshot.History = nil
	c.snapshot.UpdatedAt = time.Now()
	snapshot := c.snapshot
	c.mu.Unlock()
	c.broadcast(snapshot)
}

func prependCapped(entries []HistoryEntry, entry HistoryEntry, cap int) []HistoryEntry {
	result := make([]HistoryEntry, 0, cap)
	result = append(result, entry)
	for i := 0; i < len(entries) && len(result) < cap; i++ {
		result = append(result, entries[i])
	}
	return result
}

func (c *Controller) broadcast(snapshot Snapshot) {
	c.mu.Lock()
	defer c.mu.Unlock()
	for ch := range c.subscribers {
		select {
		case ch <- snapshot:
		default:
		}
	}
}
