package text

import (
	"context"
	"regexp"
	"strings"
)

type Transformer struct{}

func NewTransformer() *Transformer {
	return &Transformer{}
}

func (t *Transformer) CleanupTranscript(input string) string {
	input = strings.TrimSpace(input)
	input = strings.Trim(input, " \n\t\"")
	input = whitespace.ReplaceAllString(input, " ")
	return input
}

func (t *Transformer) Transform(_ context.Context, selected, instruction string) (string, error) {
	selected = strings.TrimSpace(selected)
	instruction = strings.ToLower(t.CleanupTranscript(instruction))

	switch {
	case selected == "":
		return t.CleanupTranscript(instruction), nil
	case containsAny(instruction, "bullet", "bullets", "bullet list"):
		return bulletize(selected), nil
	case containsAny(instruction, "uppercase", "all caps"):
		return strings.ToUpper(selected), nil
	case containsAny(instruction, "lowercase"):
		return strings.ToLower(selected), nil
	case containsAny(instruction, "trim", "clean up whitespace"):
		return whitespace.ReplaceAllString(selected, " "), nil
	case containsAny(instruction, "shorter", "summarize", "summary"):
		return shorten(selected), nil
	case containsAny(instruction, "fix grammar", "fix the grammar", "clean this up"):
		return cleanSentences(selected), nil
	default:
		// Until an LLM provider is configured, unknown transform instructions are
		// preserved as an explicit edit note instead of guessing at semantics.
		return selected + "\n\n[" + t.CleanupTranscript(instruction) + "]", nil
	}
}

var whitespace = regexp.MustCompile(`\s+`)

func containsAny(input string, needles ...string) bool {
	for _, needle := range needles {
		if strings.Contains(input, needle) {
			return true
		}
	}
	return false
}

func bulletize(input string) string {
	parts := splitSentences(input)
	for i, part := range parts {
		parts[i] = "- " + part
	}
	return strings.Join(parts, "\n")
}

func shorten(input string) string {
	parts := splitSentences(input)
	if len(parts) <= 2 {
		return strings.Join(parts, " ")
	}
	return strings.Join(parts[:2], " ")
}

func cleanSentences(input string) string {
	parts := splitSentences(input)
	for i, part := range parts {
		if part == "" {
			continue
		}
		parts[i] = strings.ToUpper(part[:1]) + part[1:]
		if !strings.HasSuffix(parts[i], ".") && !strings.HasSuffix(parts[i], "!") && !strings.HasSuffix(parts[i], "?") {
			parts[i] += "."
		}
	}
	return strings.Join(parts, " ")
}

func splitSentences(input string) []string {
	input = whitespace.ReplaceAllString(strings.TrimSpace(input), " ")
	if input == "" {
		return nil
	}

	raw := regexp.MustCompile(`[.!?]\s+`).Split(input, -1)
	parts := make([]string, 0, len(raw))
	for _, part := range raw {
		part = strings.TrimSpace(part)
		part = strings.Trim(part, ".!?")
		if part != "" {
			parts = append(parts, part)
		}
	}
	if len(parts) == 0 {
		return []string{input}
	}
	return parts
}
