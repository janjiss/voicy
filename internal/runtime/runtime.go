package runtime

import (
	"context"
	"fmt"

	coreapp "github.com/janis/voicy/internal/app"
	"github.com/janis/voicy/internal/audio"
	"github.com/janis/voicy/internal/ipc"
	"github.com/janis/voicy/internal/models"
	"github.com/janis/voicy/internal/settings"
	texttransform "github.com/janis/voicy/internal/text"
	"github.com/janis/voicy/internal/transcribe"
)

// Run wires the core services together and serves the native frontend over the
// stdio IPC protocol. The process is headless: all UI lives in the frontend.
//
// Accessibility-dependent integrations (the global push-to-talk hotkey and text
// injection) live in the native frontend, which is the process macOS attributes
// the Accessibility grant to. The backend only needs microphone access. It
// therefore runs without a hotkey service and injects text by asking the
// frontend over IPC.
func Run(ctx context.Context) error {
	config, err := settings.Load()
	if err != nil {
		return fmt.Errorf("load settings: %w", err)
	}

	modelManager, err := models.NewManager("Voicy")
	if err != nil {
		return fmt.Errorf("create model manager: %w", err)
	}

	server := ipc.NewServer(modelManager)

	whisper := transcribe.NewWhisper(modelManager, config.ModelName, config.WhisperBinary)
	controller := coreapp.NewController(config, coreapp.Services{
		Recorder:    audio.NewRecorder(),
		Transcriber: whisper,
		Injector:    server.Injector(),
		Transformer: texttransform.NewTransformer(),
	})
	server.Bind(controller)

	defer controller.Shutdown()

	return server.Serve(ctx)
}
