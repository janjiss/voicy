package text

import (
	"context"
	"strings"
	"testing"
)

func TestCleanupTranscript(t *testing.T) {
	transformer := NewTransformer()
	got := transformer.CleanupTranscript("  \"hello   world\" \n")
	if got != "hello world" {
		t.Fatalf("expected cleaned transcript, got %q", got)
	}
}

func TestTransformBulletizesSelectedText(t *testing.T) {
	transformer := NewTransformer()
	got, err := transformer.Transform(context.Background(), "First thing. Second thing.", "make this a bullet list")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(got, "- First thing") || !strings.Contains(got, "- Second thing") {
		t.Fatalf("expected bullet list, got %q", got)
	}
}

func TestTransformUnknownInstructionPreservesSelectedText(t *testing.T) {
	transformer := NewTransformer()
	got, err := transformer.Transform(context.Background(), "Keep me", "rewrite with sparkle")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(got, "Keep me") {
		t.Fatalf("expected original text to be preserved, got %q", got)
	}
}
