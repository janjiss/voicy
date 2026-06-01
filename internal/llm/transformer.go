package llm

import (
	"context"
	"sync"

	"github.com/janis/voicy/internal/models"
	"github.com/janis/voicy/internal/text"
)

// Transformer is the LLM-backed implementation of the controller's Transformer
// interface. It wraps the deterministic rule-based text.Transformer and only
// reaches for the local model when LLM correction is enabled and available;
// otherwise (and on any LLM error) it falls back to the rule-based behavior so
// dictation never hard-depends on the model download.
type Transformer struct {
	base   *text.Transformer
	client *Client

	mu        sync.Mutex
	enabled   bool
	modelName string
	binary    string
}

// NewTransformer builds an LLM transformer over the given model manager.
func NewTransformer(manager *models.Manager) *Transformer {
	return &Transformer{
		base:      text.NewTransformer(),
		client:    NewClient(manager, "", ""),
		modelName: models.DefaultLLMModelName,
	}
}

// SetLLM updates runtime LLM configuration. The controller calls this before
// each formatting pass so settings changes take effect without a restart.
func (t *Transformer) SetLLM(enabled bool, modelName, binary string) {
	t.mu.Lock()
	t.enabled = enabled
	if modelName != "" {
		t.modelName = modelName
	}
	t.binary = binary
	t.mu.Unlock()
}

// CleanupTranscript always runs the cheap deterministic cleanup. This is the
// pre-clean applied before any LLM pass.
func (t *Transformer) CleanupTranscript(input string) string {
	return t.base.CleanupTranscript(input)
}

// Format runs LLM post-formatting on a transcript, falling back to the
// rule-based cleanup when the model is unavailable.
func (t *Transformer) Format(ctx context.Context, transcript string) (string, error) {
	t.mu.Lock()
	enabled := t.enabled
	t.client.SetModelName(t.modelName)
	t.client.SetBinaryPath(t.binary)
	t.mu.Unlock()

	if !enabled || !t.client.Available() {
		return t.base.CleanupTranscript(transcript), nil
	}
	out, err := t.client.Format(ctx, transcript)
	if err != nil || out == "" {
		// Formatting is best-effort: never fail dictation over it.
		return t.base.CleanupTranscript(transcript), nil
	}
	return out, nil
}

// Transform applies a spoken edit instruction to selected text, using the LLM
// when enabled and available and falling back to the rule-based transformer.
func (t *Transformer) Transform(ctx context.Context, selected, instruction string) (string, error) {
	t.mu.Lock()
	enabled := t.enabled
	t.client.SetModelName(t.modelName)
	t.client.SetBinaryPath(t.binary)
	t.mu.Unlock()

	if !enabled || !t.client.Available() {
		return t.base.Transform(ctx, selected, instruction)
	}
	out, err := t.client.Edit(ctx, selected, instruction)
	if err != nil || out == "" {
		return t.base.Transform(ctx, selected, instruction)
	}
	return out, nil
}
