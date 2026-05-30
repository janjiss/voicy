//go:build darwin && !cgo

package inject

import (
	"context"
	"errors"
)

type Injector struct{}

func NewInjector() *Injector {
	return &Injector{}
}

func (i *Injector) InsertText(context.Context, string) error {
	return errors.New("macOS text insertion requires cgo")
}

type SelectionReader struct{}

func NewSelectionReader() *SelectionReader {
	return &SelectionReader{}
}

func (r *SelectionReader) SelectedText(context.Context) (string, error) {
	return "", errors.New("macOS selected text reading requires cgo")
}
