package transcribe

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

type Whisper struct {
	models     *models.Manager
	modelName  string
	binaryPath string
	timeout    time.Duration
	lastModel  string
}

func NewWhisper(manager *models.Manager, modelName, binaryPath string) *Whisper {
	if modelName == "" {
		modelName = models.DefaultModelName
	}
	return &Whisper{
		models:     manager,
		modelName:  modelName,
		binaryPath: binaryPath,
		timeout:    2 * time.Minute,
	}
}

func (w *Whisper) SetBinaryPath(path string) {
	w.binaryPath = path
}

func (w *Whisper) SetModelName(name string) {
	if name != "" {
		w.modelName = name
	}
}

func (w *Whisper) LastModelPath() string {
	return w.lastModel
}

func (w *Whisper) Transcribe(ctx context.Context, audioPath string) (string, error) {
	if w.models == nil {
		return "", errors.New("model manager is not configured")
	}

	binary, err := w.resolveBinary()
	if err != nil {
		return "", err
	}

	modelPath, err := w.models.Ensure(ctx, w.modelName, nil)
	if err != nil {
		return "", err
	}
	w.lastModel = modelPath

	runCtx, cancel := context.WithTimeout(ctx, w.timeout)
	defer cancel()

	outputBase := filepath.Join(os.TempDir(), fmt.Sprintf("voicy-whisper-%d", time.Now().UnixNano()))
	args := []string{
		"-m", modelPath,
		"-f", audioPath,
		"-otxt",
		"-of", outputBase,
		"-nt",
	}

	cmd := exec.CommandContext(runCtx, binary, args...)
	var stdout bytes.Buffer
	var stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr

	if err := cmd.Run(); err != nil {
		return "", fmt.Errorf("%s failed: %w: %s", filepath.Base(binary), err, strings.TrimSpace(stderr.String()))
	}

	txtPath := outputBase + ".txt"
	defer os.Remove(txtPath)

	if data, err := os.ReadFile(txtPath); err == nil {
		if text := strings.TrimSpace(string(data)); text != "" {
			return text, nil
		}
	}

	if text := extractTranscript(stdout.String()); text != "" {
		return text, nil
	}
	return "", errors.New("whisper produced no transcript")
}

func (w *Whisper) resolveBinary() (string, error) {
	candidates := []string{}
	if w.binaryPath != "" {
		candidates = append(candidates, w.binaryPath)
	}
	candidates = append(candidates, embeddedBinaryCandidates()...)
	candidates = append(candidates, filepath.Join("Voicy.app", "Contents", "Resources", "whisper-cli"))
	candidates = append(candidates, filepath.Join("bin", "whisper-cli"))
	candidates = append(candidates, "whisper-cli", "main", "whisper")
	for _, dir := range []string{"/opt/homebrew/bin", "/usr/local/bin"} {
		for _, name := range []string{"whisper-cli", "main", "whisper"} {
			candidates = append(candidates, filepath.Join(dir, name))
		}
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

	return "", errors.New("whisper.cpp binary not found; rebuild the app with bundled whisper-cli or configure the whisper binary path in settings")
}

func embeddedBinaryCandidates() []string {
	exe, err := os.Executable()
	if err != nil {
		return nil
	}

	exeDir := filepath.Dir(exe)
	return []string{
		filepath.Join(exeDir, "whisper-cli"),
		filepath.Join(exeDir, "..", "Resources", "whisper-cli"),
		filepath.Join(exeDir, "..", "Resources", "bin", "whisper-cli"),
	}
}

func extractTranscript(output string) string {
	lines := strings.Split(output, "\n")
	var transcript []string
	for _, line := range lines {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		if strings.HasPrefix(line, "whisper_") || strings.HasPrefix(line, "main:") {
			continue
		}
		if strings.HasPrefix(line, "[") {
			if idx := strings.Index(line, "]"); idx >= 0 && idx+1 < len(line) {
				line = strings.TrimSpace(line[idx+1:])
			}
		}
		if line != "" {
			transcript = append(transcript, line)
		}
	}
	return strings.TrimSpace(strings.Join(transcript, " "))
}
