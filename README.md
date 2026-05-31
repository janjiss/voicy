# Voicy

Voicy is a desktop dictation app with a headless Go backend and native frontends, powered by miniaudio and `whisper.cpp`.
<img width="501" height="591" alt="image" src="https://github.com/user-attachments/assets/4257f25f-ed75-4bf3-b90f-3f7c662e7310" />

The backend is UI-agnostic: it speaks a small newline-delimited JSON protocol over stdio (see `internal/uiproto`). A native frontend spawns the backend and drives it over that protocol. macOS ships a native Swift (AppKit + SwiftUI) frontend today; Linux can add its own frontend later by speaking the same protocol. The core OS integrations stay behind small Go package interfaces.

## Current Features

- Native macOS frontend: menu-bar item, SwiftUI settings window, and a floating HUD overlay.
- Headless Go backend driven over a stdio JSON protocol (the cross-platform adapter seam).
- Push-to-talk recording flow.
- Cross-platform microphone capture through miniaudio.
- `whisper.cpp` sidecar transcription with `large-v3-turbo`.
- Automatic model download/cache.
- macOS text insertion through clipboard paste.
- macOS selected-text transform path.

## Requirements

- Go 1.25 or newer.
- Swift 5.9+ / Xcode command-line tools (for the macOS frontend).
- A working C toolchain for miniaudio and the cgo OS integrations.
- CMake and Git for building the bundled `whisper.cpp` sidecar.

macOS also needs:

- Microphone permission.
- Accessibility permission for global hotkeys and text insertion.

## Run

During development, build the Go backend and launch the Swift frontend pointed at it (no `.app` bundle required):

```sh
make run
```

This builds `dist/voicy-backend`, then runs `swift run` in `macos/` with `VOICY_BACKEND` set so the frontend spawns the local backend binary. You can also run the backend by hand and feed it the JSON protocol on stdin:

```sh
go run ./cmd/voicy
```

Run diagnostics for permissions, bundled Whisper, and global hotkey capture:

```sh
go run ./cmd/voicycheck -key right_option -seconds 20
```

To test insertion separately, focus a text field after starting this command:

```sh
go run ./cmd/voicycheck -seconds 5 -paste "hello from voicy"
```

Run the transcription loop entirely in the console:

```sh
go run ./cmd/voicyrec -seconds 5
```

This records for five seconds, transcribes the clip, and prints the transcript to stdout.

The app stores settings in the OS config directory and models in the OS cache directory. By default it downloads:

```text
ggml-large-v3-turbo-q5_0.bin
```

from the `ggerganov/whisper.cpp` Hugging Face repository.

## Build

Build just the backend helper:

```sh
go build -o dist/voicy-backend ./cmd/voicy
```

Assemble the native macOS app (Swift frontend + Go backend helper):

```sh
make macos-app
```

Build a release bundle with the bundled Whisper sidecar:

```sh
make package-macos
```

`make package-macos` builds `whisper.cpp` under `third_party/whisper.cpp`, assembles `Voicy.app` (Swift frontend as the bundle main executable in `Contents/MacOS/Voicy`, the Go backend in `Contents/MacOS/voicy-backend`), and copies `whisper-cli` into `Voicy.app/Contents/Resources/`. The model itself is still downloaded on demand because `large-v3-turbo` is too large to bundle into the app by default.

## Architecture

The backend and frontend are separate processes connected by a stdio JSON protocol. The frontend spawns the backend and exchanges newline-delimited JSON: the backend streams UI state and events on stdout, the frontend writes commands on stdin.

```text
macos/                  native Swift frontend (menu bar, settings, HUD, IPC client)
cmd/voicy               headless Go backend entry point
  internal/runtime      wires services together and serves the IPC protocol
  internal/ipc          stdio JSON server: streams events, dispatches commands
  internal/uiproto      shared wire protocol (the cross-platform adapter seam)
  internal/app          state machine and orchestration
  internal/audio        microphone capture and WAV output
  internal/models       model download/cache
  internal/transcribe   whisper.cpp sidecar runner
  internal/text         cleanup and transform pipeline
  internal/hotkey       push-to-talk adapters
  internal/inject       text insertion and selected text adapters
  internal/permissions  platform permission helpers
```

### Adding a frontend (e.g. Linux)

A new frontend only needs to: spawn the `voicy-backend` binary, read events (`state`, `levels`, `permissions`, `modelProgress`) from its stdout, and write commands (`beginRecording`, `finishRecording`, `quickTest`, `updateConfig`, `downloadModel`, `clearHistory`, `openAccessibilitySettings`, `openMicrophoneSettings`, `shutdown`) to its stdin. No changes to the Go core are required.

## Platform Notes

macOS is the implemented path. The default push-to-talk key is `right_option`. `fn` is available as an experimental option, but it may not be exposed reliably on all keyboards or macOS settings.

The Go backend (spawned as a child of the Swift app) is the process that performs accessibility and microphone work, so macOS attributes those TCC permission prompts to the backend binary. Unsigned development builds reset accessibility grants when the binary is rebuilt; after granting accessibility for a freshly built `Voicy.app`, fully quit and relaunch.

Linux support is planned via a separate native frontend that speaks the same stdio protocol. Wayland support is expected to remain limited because many compositors block global hotkeys and synthetic input.
