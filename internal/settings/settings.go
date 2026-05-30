package settings

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"

	"github.com/janis/voicy/internal/app"
	"github.com/janis/voicy/internal/models"
)

const appName = "Voicy"

func DefaultConfig() app.Config {
	return app.Config{
		PushToTalkKey:     "right_option",
		ModelName:         models.DefaultModelName,
		AutoInsert:        true,
		TransformSelected: false,
	}
}

func Load() (app.Config, error) {
	config := DefaultConfig()
	path, err := path()
	if err != nil {
		return config, err
	}

	data, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return config, nil
	}
	if err != nil {
		return config, err
	}
	if err := json.Unmarshal(data, &config); err != nil {
		return config, err
	}
	migrate(&config)
	return config, nil
}

func migrate(config *app.Config) {
	if config.PushToTalkKey == "" || config.PushToTalkKey == "fn" {
		config.PushToTalkKey = "right_option"
	}

	// Keep the first-run dictation path boring: selected-text transforms need
	// stronger active-app tracking than this prototype has today.
	config.TransformSelected = false
}

func Save(config app.Config) error {
	path, err := path()
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	data, err := json.MarshalIndent(config, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(path, data, 0o644)
}

func path() (string, error) {
	dir, err := os.UserConfigDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(dir, appName, "settings.json"), nil
}
