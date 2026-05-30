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

type Model struct {
	Name   string
	URL    string
	SHA256 string
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
		},
	}, nil
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
