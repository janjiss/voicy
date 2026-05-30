//go:build !darwin || !cgo

package permissions

import "context"

type Status struct {
	Accessibility bool
	Microphone    bool
	Notes         []string
}

func Check(context.Context) Status {
	return Status{
		Accessibility: false,
		Microphone:    true,
		Notes: []string{
			"Permission checks are platform-specific and not implemented for this OS yet.",
		},
	}
}

func OpenAccessibilitySettings(context.Context) error {
	return nil
}

func OpenMicrophoneSettings(context.Context) error {
	return nil
}
