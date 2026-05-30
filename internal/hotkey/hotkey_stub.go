//go:build !darwin || !cgo

package hotkey

import (
	"context"

	"github.com/janis/voicy/internal/app"
)

type Service struct {
	key string
}

func NewService(key string) *Service {
	if key == "" {
		key = "fn"
	}
	return &Service{key: key}
}

func (s *Service) SetKey(key string) {
	if key == "" {
		key = "fn"
	}
	s.key = key
}

func (s *Service) Start(context.Context, app.HotkeyCallbacks) error {
	return nil
}

func (s *Service) Stop() error {
	return nil
}
