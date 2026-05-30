//go:build windows

package inject

import (
	"bytes"
	"context"
	"errors"
	"os/exec"
)

type Injector struct{}

func NewInjector() *Injector {
	return &Injector{}
}

func (i *Injector) InsertText(ctx context.Context, text string) error {
	cmd := exec.CommandContext(ctx, "powershell", "-NoProfile", "-Command", "Set-Clipboard -Value ([Console]::In.ReadToEnd()); Add-Type -AssemblyName System.Windows.Forms; [System.Windows.Forms.SendKeys]::SendWait('^v')")
	cmd.Stdin = bytes.NewBufferString(text)
	return cmd.Run()
}

type SelectionReader struct{}

func NewSelectionReader() *SelectionReader {
	return &SelectionReader{}
}

func (r *SelectionReader) SelectedText(context.Context) (string, error) {
	return "", errors.New("selected text reading is not implemented on Windows yet")
}
