// Package llm runs a local llama.cpp sidecar to post-format dictated text and
// apply spoken edit instructions. It mirrors internal/transcribe: a one-shot
// CLI (llama-cli) is spawned per request, the GGUF model is fetched and cached
// through internal/models, and the binary is resolved relative to the app
// bundle. Keeping the model resident is avoided on purpose; llama.cpp mmaps the
// weights, so warm runs reload in well under a second for these small models.
package llm

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/janis/voicy/internal/models"
)

// Client invokes the llama.cpp sidecar for a single formatting or edit request.
type Client struct {
	models     *models.Manager
	modelName  string
	binaryPath string
	timeout    time.Duration
	contextLen int
	maxTokens  int
}

// NewClient creates a client bound to a model manager. modelName may be empty,
// in which case the default correction model is used.
func NewClient(manager *models.Manager, modelName, binaryPath string) *Client {
	if modelName == "" {
		modelName = models.DefaultLLMModelName
	}
	return &Client{
		models:     manager,
		modelName:  modelName,
		binaryPath: binaryPath,
		timeout:    60 * time.Second,
		contextLen: 4096,
		maxTokens:  1024,
	}
}

func (c *Client) SetModelName(name string) {
	if name != "" {
		c.modelName = name
	}
}

func (c *Client) SetBinaryPath(path string) {
	c.binaryPath = path
}

// ModelName reports the currently selected correction model.
func (c *Client) ModelName() string { return c.modelName }

// Available reports whether both the sidecar binary and the selected model are
// present, so callers can decide whether to attempt an LLM call at all.
func (c *Client) Available() bool {
	if _, err := c.resolveBinary(); err != nil {
		return false
	}
	return c.models != nil && c.models.Installed(c.modelName)
}

// Format cleans up a raw transcript: punctuation, casing, filler-word removal,
// without changing meaning.
func (c *Client) Format(ctx context.Context, transcript string) (string, error) {
	transcript = strings.TrimSpace(transcript)
	if transcript == "" {
		return "", nil
	}
	system, user := buildFormatPrompt(c.family(), transcript)
	return c.run(ctx, system, user)
}

// Edit applies a spoken instruction to a block of selected text.
func (c *Client) Edit(ctx context.Context, selected, instruction string) (string, error) {
	selected = strings.TrimSpace(selected)
	instruction = strings.TrimSpace(instruction)
	if instruction == "" {
		return selected, nil
	}
	system, user := buildEditPrompt(c.family(), selected, instruction)
	return c.run(ctx, system, user)
}

func (c *Client) family() models.Family {
	if c.models != nil {
		if model, ok := c.models.Lookup(c.modelName); ok && model.Family != "" {
			return model.Family
		}
	}
	return models.FamilyLlama
}

func (c *Client) run(ctx context.Context, system, user string) (string, error) {
	if c.models == nil {
		return "", errors.New("model manager is not configured")
	}

	binary, err := c.resolveBinary()
	if err != nil {
		return "", err
	}

	modelPath, err := c.models.Ensure(ctx, c.modelName, nil)
	if err != nil {
		return "", err
	}

	runCtx, cancel := context.WithTimeout(ctx, c.timeout)
	defer cancel()

	args := []string{
		"-m", modelPath,
		"--jinja", // apply the GGUF's built-in chat template (per-family roles)
		"-sys", system,
		"-p", user,
		"-no-cnv",             // single, non-interactive turn
		"-st",                 // stop after one assistant turn
		"--no-display-prompt", // stdout carries only the generated text
		"-n", fmt.Sprintf("%d", c.maxTokens),
		"-c", fmt.Sprintf("%d", c.contextLen),
		"--temp", "0", // deterministic: no creative rewriting
		"--no-warmup",
	}

	cmd := exec.CommandContext(runCtx, binary, args...)
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr

	if err := cmd.Run(); err != nil {
		return "", fmt.Errorf("%s failed: %w: %s", filepath.Base(binary), err, strings.TrimSpace(lastLines(stderr.String(), 3)))
	}

	result := sanitize(stdout.String())
	if result == "" {
		return "", errors.New("llm produced no output")
	}
	return result, nil
}

func (c *Client) resolveBinary() (string, error) {
	candidates := []string{}
	if c.binaryPath != "" {
		candidates = append(candidates, c.binaryPath)
	}
	candidates = append(candidates, embeddedBinaryCandidates()...)
	candidates = append(candidates, filepath.Join("Voicy.app", "Contents", "Resources", "llama-cli"))
	candidates = append(candidates, filepath.Join("bin", "llama-cli"))
	candidates = append(candidates, "llama-cli")
	for _, dir := range []string{"/opt/homebrew/bin", "/usr/local/bin"} {
		candidates = append(candidates, filepath.Join(dir, "llama-cli"))
	}

	for _, candidate := range candidates {
		if strings.ContainsAny(candidate, `/\`) {
			info, err := os.Stat(candidate)
			if err == nil && !info.IsDir() {
				return candidate, nil
			}
			continue
		}
		if path, err := exec.LookPath(candidate); err == nil {
			return path, nil
		}
	}

	return "", errors.New("llama.cpp binary not found; rebuild the app with bundled llama-cli or set the LLM binary path in settings")
}

func embeddedBinaryCandidates() []string {
	exe, err := os.Executable()
	if err != nil {
		return nil
	}
	exeDir := filepath.Dir(exe)
	return []string{
		filepath.Join(exeDir, "llama-cli"),
		filepath.Join(exeDir, "..", "Resources", "llama-cli"),
		filepath.Join(exeDir, "..", "Resources", "bin", "llama-cli"),
	}
}

func lastLines(s string, n int) string {
	lines := strings.Split(strings.TrimSpace(s), "\n")
	if len(lines) > n {
		lines = lines[len(lines)-n:]
	}
	return strings.Join(lines, "\n")
}
