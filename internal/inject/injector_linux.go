//go:build linux

package inject

import (
	"context"
	"errors"
	"os/exec"
)

type Injector struct{}

func NewInjector() *Injector {
	return &Injector{}
}

func (i *Injector) InsertText(ctx context.Context, text string) error {
	if _, err := exec.LookPath("wl-copy"); err == nil {
		return errors.New("Wayland clipboard is available, but trusted text insertion is compositor-specific")
	}
	if _, err := exec.LookPath("xdotool"); err != nil {
		return errors.New("install xdotool for X11 text insertion")
	}
	cmd := exec.CommandContext(ctx, "xdotool", "type", "--clearmodifiers", "--", text)
	return cmd.Run()
}

type SelectionReader struct{}

func NewSelectionReader() *SelectionReader {
	return &SelectionReader{}
}

func (r *SelectionReader) SelectedText(context.Context) (string, error) {
	return "", errors.New("selected text reading is not implemented on Linux yet")
}
