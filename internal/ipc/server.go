// Package ipc implements the backend side of the newline-delimited JSON UI
// protocol described in internal/uiproto. It streams UI state to stdout and
// dispatches commands read from stdin to the core controller, model manager,
// and permission helpers.
package ipc

import (
	"bufio"
	"context"
	"encoding/json"
	"io"
	"os"
	"sync"
	"time"

	coreapp "github.com/janis/voicy/internal/app"
	"github.com/janis/voicy/internal/models"
	"github.com/janis/voicy/internal/permissions"
	"github.com/janis/voicy/internal/settings"
	"github.com/janis/voicy/internal/uiproto"
)

// Server bridges the core controller to a native frontend over stdio.
type Server struct {
	controller *coreapp.Controller
	models     *models.Manager
	injector   *Injector

	in  io.Reader
	out io.Writer

	writeMu sync.Mutex
	enc     *json.Encoder
}

// NewServer creates a server that talks the UI protocol over stdin/stdout.
// Call Injector before constructing the controller, Bind once the controller
// exists, then Serve to run the loop.
func NewServer(modelManager *models.Manager) *Server {
	s := &Server{
		models: modelManager,
		in:     os.Stdin,
		out:    os.Stdout,
		enc:    json.NewEncoder(os.Stdout),
	}
	s.injector = &Injector{emit: func(text string) {
		s.emit(uiproto.EventInsertText, uiproto.InsertText{Text: text})
	}}
	return s
}

// Injector returns a TextInjector that forwards insertion requests to the
// frontend over IPC (the frontend holds Accessibility and performs the paste).
func (s *Server) Injector() coreapp.TextInjector {
	return s.injector
}

func (s *Server) Clipboard() coreapp.ClipboardWriter {
	return &Clipboard{emit: func(text string) {
		s.emit(uiproto.EventCopyText, uiproto.CopyText{Text: text})
	}}
}

// Bind attaches the controller the server dispatches commands to.
func (s *Server) Bind(controller *coreapp.Controller) {
	s.controller = controller
}

// Serve runs the IPC loop, blocking until the context is cancelled or stdin
// reaches EOF (the frontend exited).
func (s *Server) Serve(ctx context.Context) error {
	return s.run(ctx)
}

func (s *Server) run(ctx context.Context) error {
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()

	go s.streamState(ctx)
	go s.streamLevels(ctx)
	go s.streamPermissions(ctx)

	// Tell the frontend which models are already cached so it doesn't show a
	// download affordance/progress for them.
	s.emitModels()

	// Reading stdin drives the lifetime: when the frontend closes the pipe we
	// shut down the backend.
	s.readCommands(ctx, cancel)
	return nil
}

func (s *Server) emitModels() {
	s.emit(uiproto.EventModels, uiproto.Models{Installed: s.models.InstalledModels()})
}

func (s *Server) emit(eventType string, payload interface{}) {
	s.writeMu.Lock()
	defer s.writeMu.Unlock()
	_ = s.enc.Encode(uiproto.Event{Type: eventType, Payload: payload})
}

func (s *Server) streamState(ctx context.Context) {
	for snapshot := range s.controller.Subscribe(ctx) {
		s.emit(uiproto.EventState, toViewState(snapshot))
	}
}

func (s *Server) streamLevels(ctx context.Context) {
	ticker := time.NewTicker(80 * time.Millisecond)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			current, session := s.controller.AudioLevel()
			if current == 0 && session == 0 {
				continue
			}
			s.emit(uiproto.EventLevels, uiproto.Levels{Current: current, Session: session})
		}
	}
}

func (s *Server) streamPermissions(ctx context.Context) {
	tick := func() {
		status := permissions.Check(ctx)
		s.emit(uiproto.EventPermissions, uiproto.Permissions{
			Accessibility: status.Accessibility,
			Microphone:    status.Microphone,
		})
	}
	tick()

	ticker := time.NewTicker(2 * time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			tick()
		}
	}
}

func (s *Server) readCommands(ctx context.Context, cancel context.CancelFunc) {
	scanner := bufio.NewScanner(s.in)
	scanner.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	for scanner.Scan() {
		line := scanner.Bytes()
		if len(line) == 0 {
			continue
		}
		var cmd uiproto.Command
		if err := json.Unmarshal(line, &cmd); err != nil {
			continue
		}
		if s.dispatch(ctx, cmd) {
			break
		}
	}
	cancel()
}

// dispatch handles a single command and returns true when the backend should
// stop serving.
func (s *Server) dispatch(ctx context.Context, cmd uiproto.Command) (stop bool) {
	switch cmd.Type {
	case uiproto.CommandBeginRecording:
		if err := s.controller.BeginRecording(ctx); err != nil {
			s.controller.ReportError(err)
		}
	case uiproto.CommandFinishRecording:
		go s.controller.FinishRecording(ctx)
	case uiproto.CommandQuickTest:
		go s.quickTest(ctx)
	case uiproto.CommandUpdateConfig:
		if cmd.Payload.Config != nil {
			s.updateConfig(*cmd.Payload.Config)
		}
	case uiproto.CommandDownloadModel:
		go s.downloadModel(ctx, cmd.Payload.ModelName)
	case uiproto.CommandClearHistory:
		s.controller.ClearHistory()
	case uiproto.CommandOpenAccessibility:
		_ = permissions.OpenAccessibilitySettings(ctx)
	case uiproto.CommandOpenMicrophone:
		_ = permissions.OpenMicrophoneSettings(ctx)
	case uiproto.CommandShutdown:
		return true
	}
	return false
}

func (s *Server) quickTest(ctx context.Context) {
	if err := s.controller.BeginRecording(ctx); err != nil {
		s.controller.ReportError(err)
		return
	}
	time.Sleep(3 * time.Second)
	s.controller.FinishRecording(ctx)
}

func (s *Server) updateConfig(wire uiproto.Config) {
	config := fromWireConfig(wire)
	s.controller.UpdateConfig(config)
	if err := settings.Save(config); err != nil {
		s.controller.ReportError(err)
	}
}

func (s *Server) downloadModel(ctx context.Context, name string) {
	if name == "" {
		name = s.controller.Snapshot().Config.ModelName
	}
	_, err := s.models.Ensure(ctx, name, func(downloaded, total int64) {
		s.emit(uiproto.EventModelProgress, uiproto.ModelProgress{
			Name:       name,
			Downloaded: downloaded,
			Total:      total,
		})
	})
	progress := uiproto.ModelProgress{Name: name, Done: true}
	if err != nil {
		progress.Error = err.Error()
	}
	s.emit(uiproto.EventModelProgress, progress)
	// Refresh installed state so a freshly downloaded model is now marked as
	// present (and a failed one is not).
	s.emitModels()
}

func toViewState(snapshot coreapp.Snapshot) uiproto.ViewState {
	history := make([]uiproto.HistoryEntry, 0, len(snapshot.History))
	for _, entry := range snapshot.History {
		history = append(history, uiproto.HistoryEntry{
			At:         entry.At.Format(time.RFC3339),
			Transcript: entry.Transcript,
		})
	}
	return uiproto.ViewState{
		State:          string(snapshot.State),
		Config:         toWireConfig(snapshot.Config),
		LastTranscript: snapshot.LastTranscript,
		LastInserted:   snapshot.LastInserted,
		LastError:      snapshot.LastError,
		History:        history,
		UpdatedAt:      snapshot.UpdatedAt.Format(time.RFC3339),
	}
}

func toWireConfig(config coreapp.Config) uiproto.Config {
	return uiproto.Config{
		PushToTalkKey:     config.PushToTalkKey,
		HotkeyMappings:    toWireHotkeyMappings(config.HotkeyMappings),
		WhisperBinary:     config.WhisperBinary,
		ModelName:         config.ModelName,
		AutoInsert:        config.AutoInsert,
		TransformSelected: config.TransformSelected,
		RecordingMode:     config.RecordingMode,
		CopyToClipboard:   config.CopyToClipboard,
		PauseMusic:        config.PauseMusic,
		FormatWithLLM:     config.FormatWithLLM,
		LLMModelName:      config.LLMModelName,
		LLMBinary:         config.LLMBinary,
	}
}

func fromWireConfig(config uiproto.Config) coreapp.Config {
	return coreapp.Config{
		PushToTalkKey:     config.PushToTalkKey,
		HotkeyMappings:    fromWireHotkeyMappings(config.HotkeyMappings),
		WhisperBinary:     config.WhisperBinary,
		ModelName:         config.ModelName,
		AutoInsert:        config.AutoInsert,
		TransformSelected: config.TransformSelected,
		RecordingMode:     config.RecordingMode,
		CopyToClipboard:   config.CopyToClipboard,
		PauseMusic:        config.PauseMusic,
		FormatWithLLM:     config.FormatWithLLM,
		LLMModelName:      config.LLMModelName,
		LLMBinary:         config.LLMBinary,
	}
}

func toWireHotkeyMappings(mappings []coreapp.HotkeyMapping) []uiproto.HotkeyMapping {
	result := make([]uiproto.HotkeyMapping, 0, len(mappings))
	for _, mapping := range mappings {
		result = append(result, uiproto.HotkeyMapping{
			ID:    mapping.ID,
			Keys:  mapping.Keys,
			Mode:  mapping.Mode,
			Label: mapping.Label,
		})
	}
	return result
}

func fromWireHotkeyMappings(mappings []uiproto.HotkeyMapping) []coreapp.HotkeyMapping {
	result := make([]coreapp.HotkeyMapping, 0, len(mappings))
	for _, mapping := range mappings {
		result = append(result, coreapp.HotkeyMapping{
			ID:    mapping.ID,
			Keys:  mapping.Keys,
			Mode:  mapping.Mode,
			Label: mapping.Label,
		})
	}
	return result
}
