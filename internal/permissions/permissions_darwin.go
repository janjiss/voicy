//go:build darwin && cgo

package permissions

/*
#cgo darwin LDFLAGS: -framework ApplicationServices
#include <ApplicationServices/ApplicationServices.h>

static int voicyAXTrusted(void) {
	return AXIsProcessTrusted();
}
*/
import "C"

import (
	"context"
	"os/exec"
)

type Status struct {
	Accessibility bool
	Microphone    bool
	Notes         []string
}

func Check(context.Context) Status {
	return Status{
		Accessibility: C.voicyAXTrusted() == 1,
		Microphone:    true,
		Notes: []string{
			"macOS prompts for microphone access the first time recording starts.",
			"Accessibility is required for global hotkeys and text insertion.",
		},
	}
}

func OpenAccessibilitySettings(ctx context.Context) error {
	return exec.CommandContext(ctx, "open", "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility").Run()
}

func OpenMicrophoneSettings(ctx context.Context) error {
	return exec.CommandContext(ctx, "open", "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone").Run()
}
