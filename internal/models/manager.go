package models

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
)

const DefaultModelName = "ggml-large-v3-turbo-q5_0.bin"

// LLM correction models. These are general-purpose instruction-tuned models in
// GGUF form that the llama.cpp sidecar uses to clean up and reformat dictated
// text. Recent research shows well-prompted general models beat purpose-built
// grammar models at this task, so we ship a small spread across the
// quality/speed curve and let the user choose.
const (
	// DefaultLLMModelName is the recommended default: lightest fully-capable
	// model, fast, with the broadest community testing.
	DefaultLLMModelName = "Llama-3.2-3B-Instruct-Q4_K_M.gguf"
	// LLMModelQwen3_4B is the highest-accuracy pick for grammar/punctuation
	// correction in this size class.
	LLMModelQwen3_4B = "Qwen3-4B-Q4_K_M.gguf"
	// LLMModelGemma3_4B is strong on multilingual text (140+ languages).
	LLMModelGemma3_4B = "gemma-3-4b-it-Q4_K_M.gguf"
)

// Family identifies the prompt/chat-template conventions a model needs.
type Family string

const (
	FamilyWhisper Family = "whisper"
	FamilyLlama   Family = "llama"
	FamilyQwen3   Family = "qwen3"
	FamilyGemma3  Family = "gemma3"
)

type Model struct {
	Name   string
	URL    string
	SHA256 string
	// Family is empty for whisper models and set for LLM correction models so
	// the llm sidecar can tailor prompting per model.
	Family Family
	// Kind distinguishes transcription models from text-correction LLMs so the
	// UI can list them separately.
	LLM bool
}

type Manager struct {
	dir    string
	models map[string]Model
}

func NewManager(appName string) (*Manager, error) {
	cacheDir, err := os.UserCacheDir()
	if err != nil {
		return nil, err
	}

	dir := filepath.Join(cacheDir, appName, "models")
	return &Manager{
		dir: dir,
		models: map[string]Model{
			DefaultModelName: {
				Name: DefaultModelName,
				URL:  "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/" + DefaultModelName,
			},
			"ggml-large-v3-turbo.bin": {
				Name: "ggml-large-v3-turbo.bin",
				URL:  "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin",
			},
			DefaultLLMModelName: {
				Name:   DefaultLLMModelName,
				URL:    "https://huggingface.co/bartowski/Llama-3.2-3B-Instruct-GGUF/resolve/main/Llama-3.2-3B-Instruct-Q4_K_M.gguf",
				Family: FamilyLlama,
				LLM:    true,
			},
			LLMModelQwen3_4B: {
				Name:   LLMModelQwen3_4B,
				URL:    "https://huggingface.co/Qwen/Qwen3-4B-GGUF/resolve/main/Qwen3-4B-Q4_K_M.gguf",
				Family: FamilyQwen3,
				LLM:    true,
			},
			LLMModelGemma3_4B: {
				Name:   LLMModelGemma3_4B,
				URL:    "https://huggingface.co/unsloth/gemma-3-4b-it-GGUF/resolve/main/gemma-3-4b-it-Q4_K_M.gguf",
				Family: FamilyGemma3,
				LLM:    true,
			},
		},
	}, nil
}

// Lookup returns the registered model metadata for a name.
func (m *Manager) Lookup(name string) (Model, bool) {
	model, ok := m.models[name]
	return model, ok
}

// Installed reports whether a model file already exists locally (non-empty).
func (m *Manager) Installed(name string) bool {
	info, err := os.Stat(m.Path(name))
	return err == nil && info.Size() > 0
}

// InstalledModels returns the names of all registered models present locally.
func (m *Manager) InstalledModels() []string {
	names := make([]string, 0, len(m.models))
	for name := range m.models {
		if m.Installed(name) {
			names = append(names, name)
		}
	}
	return names
}

func (m *Manager) Directory() string {
	return m.dir
}

func (m *Manager) Models() []Model {
	result := make([]Model, 0, len(m.models))
	for _, model := range m.models {
		result = append(result, model)
	}
	return result
}

func (m *Manager) Path(name string) string {
	return filepath.Join(m.dir, name)
}

func (m *Manager) Ensure(ctx context.Context, name string, progress func(downloaded, total int64)) (string, error) {
	model, ok := m.models[name]
	if !ok {
		return "", fmt.Errorf("unknown model %q", name)
	}

	path := m.Path(model.Name)
	if ok, err := m.verifyExisting(path, model.SHA256); err != nil {
		return "", err
	} else if ok {
		return path, nil
	}

	if err := os.MkdirAll(m.dir, 0o755); err != nil {
		return "", err
	}

	tmp := path + ".download"
	if err := m.download(ctx, model, tmp, progress); err != nil {
		_ = os.Remove(tmp)
		return "", err
	}

	if model.SHA256 != "" {
		sum, err := fileSHA256(tmp)
		if err != nil {
			_ = os.Remove(tmp)
			return "", err
		}
		if sum != model.SHA256 {
			_ = os.Remove(tmp)
			return "", fmt.Errorf("model checksum mismatch: got %s", sum)
		}
	}

	if err := os.Rename(tmp, path); err != nil {
		return "", err
	}
	return path, nil
}

func (m *Manager) verifyExisting(path, expectedSHA string) (bool, error) {
	info, err := os.Stat(path)
	if errors.Is(err, os.ErrNotExist) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	if info.Size() == 0 {
		return false, nil
	}
	if expectedSHA == "" {
		return true, nil
	}
	sum, err := fileSHA256(path)
	if err != nil {
		return false, err
	}
	return sum == expectedSHA, nil
}

func (m *Manager) download(ctx context.Context, model Model, path string, progress func(downloaded, total int64)) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, model.URL, nil)
	if err != nil {
		return err
	}

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return fmt.Errorf("download model: %s", resp.Status)
	}

	file, err := os.Create(path)
	if err != nil {
		return err
	}
	defer file.Close()

	writer := &progressWriter{
		writer:   file,
		total:    resp.ContentLength,
		progress: progress,
	}
	_, err = io.Copy(writer, resp.Body)
	return err
}

type progressWriter struct {
	writer     io.Writer
	downloaded int64
	total      int64
	progress   func(downloaded, total int64)
}

func (w *progressWriter) Write(p []byte) (int, error) {
	n, err := w.writer.Write(p)
	w.downloaded += int64(n)
	if w.progress != nil {
		w.progress(w.downloaded, w.total)
	}
	return n, err
}

func fileSHA256(path string) (string, error) {
	file, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer file.Close()

	hash := sha256.New()
	if _, err := io.Copy(hash, file); err != nil {
		return "", err
	}
	return hex.EncodeToString(hash.Sum(nil)), nil
}
