package ipc

import "context"

// Injector implements app.TextInjector by emitting an EventInsertText event to
// the frontend. On macOS the frontend holds the Accessibility permission and
// performs the actual clipboard paste, so the backend never synthesizes input
// itself. Injection is fire-and-forget: the controller flow does not block on
// the frontend completing the paste.
type Injector struct {
	emit func(text string)
}

func (i *Injector) InsertText(_ context.Context, text string) error {
	if i.emit != nil {
		i.emit(text)
	}
	return nil
}
