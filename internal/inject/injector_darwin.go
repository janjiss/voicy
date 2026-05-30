//go:build darwin && cgo

package inject

/*
#cgo darwin LDFLAGS: -framework ApplicationServices
#include <ApplicationServices/ApplicationServices.h>

static void voicyPostCommandKey(CGKeyCode keycode) {
	CGEventSourceRef source = CGEventSourceCreate(kCGEventSourceStateHIDSystemState);
	CGEventRef down = CGEventCreateKeyboardEvent(source, keycode, true);
	CGEventRef up = CGEventCreateKeyboardEvent(source, keycode, false);

	CGEventSetFlags(down, kCGEventFlagMaskCommand);
	CGEventSetFlags(up, kCGEventFlagMaskCommand);

	CGEventPost(kCGHIDEventTap, down);
	CGEventPost(kCGHIDEventTap, up);

	CFRelease(down);
	CFRelease(up);
	CFRelease(source);
}
*/
import "C"

import (
	"bytes"
	"context"
	"fmt"
	"os/exec"
	"time"
)

type Injector struct{}

func NewInjector() *Injector {
	return &Injector{}
}

func (i *Injector) InsertText(ctx context.Context, text string) error {
	if err := setClipboard(ctx, text); err != nil {
		return err
	}
	return paste(ctx)
}

type SelectionReader struct{}

func NewSelectionReader() *SelectionReader {
	return &SelectionReader{}
}

func (r *SelectionReader) SelectedText(ctx context.Context) (string, error) {
	previous, _ := getClipboard(ctx)
	if err := copySelection(ctx); err != nil {
		return "", err
	}
	time.Sleep(150 * time.Millisecond)

	selected, err := getClipboard(ctx)
	if previous != "" {
		_ = setClipboard(ctx, previous)
	}
	return selected, err
}

func setClipboard(ctx context.Context, text string) error {
	cmd := exec.CommandContext(ctx, "pbcopy")
	cmd.Stdin = bytes.NewBufferString(text)
	if output, err := cmd.CombinedOutput(); err != nil {
		return fmt.Errorf("pbcopy: %w: %s", err, string(output))
	}
	return nil
}

func getClipboard(ctx context.Context) (string, error) {
	out, err := exec.CommandContext(ctx, "pbpaste").Output()
	if err != nil {
		return "", err
	}
	return string(out), nil
}

func copySelection(ctx context.Context) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	postCommandKey(8)
	return nil
}

func paste(ctx context.Context) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	postCommandKey(9)
	return nil
}

func postCommandKey(keycode C.CGKeyCode) {
	C.voicyPostCommandKey(keycode)
	time.Sleep(100 * time.Millisecond)
}
