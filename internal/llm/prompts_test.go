package llm

import (
	"strings"
	"testing"

	"github.com/janis/voicy/internal/models"
)

func TestSanitizeStripsThinkBlocksAndMarkers(t *testing.T) {
	in := "<think>let me reason about this</think>\nHello world. [end of text]"
	got := sanitize(in)
	if got != "Hello world." {
		t.Fatalf("expected reasoning and markers stripped, got %q", got)
	}
}

func TestSanitizeStripsWrappingQuotes(t *testing.T) {
	if got := sanitize("\"Ship it on Friday.\""); got != "Ship it on Friday." {
		t.Fatalf("expected unwrapped text, got %q", got)
	}
}

func TestQwenPromptDisablesThinking(t *testing.T) {
	system, _ := buildFormatPrompt(models.FamilyQwen3, "hello")
	if !strings.Contains(system, "/no_think") {
		t.Fatalf("expected qwen3 prompt to disable thinking, got %q", system)
	}
	system, _ = buildFormatPrompt(models.FamilyLlama, "hello")
	if strings.Contains(system, "/no_think") {
		t.Fatalf("did not expect /no_think for llama, got %q", system)
	}
}

func TestEditPromptIncludesDocumentAndInstruction(t *testing.T) {
	_, user := buildEditPrompt(models.FamilyGemma3, "the doc", "make it formal")
	if !strings.Contains(user, "the doc") || !strings.Contains(user, "make it formal") {
		t.Fatalf("edit prompt missing parts, got %q", user)
	}
}
