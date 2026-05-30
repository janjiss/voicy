package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sync/atomic"
	"time"

	"github.com/janis/voicy/internal/app"
	"github.com/janis/voicy/internal/hotkey"
	"github.com/janis/voicy/internal/inject"
	"github.com/janis/voicy/internal/permissions"
)

func main() {
	key := flag.String("key", "right_option", "push-to-talk key to monitor")
	seconds := flag.Int("seconds", 20, "seconds to monitor global hotkey events")
	paste := flag.String("paste", "", "optional text to paste into the focused app after a countdown")
	flag.Parse()

	ctx, cancel := context.WithTimeout(context.Background(), time.Duration(*seconds)*time.Second)
	defer cancel()

	fmt.Println("Voicy diagnostic")
	fmt.Printf("Executable: %s\n", mustExecutable())
	fmt.Printf("Key: %s\n", *key)

	status := permissions.Check(context.Background())
	fmt.Printf("Accessibility trusted: %t\n", status.Accessibility)
	for _, note := range status.Notes {
		fmt.Printf("Permission note: %s\n", note)
	}

	checkWhisper()

	if *paste != "" {
		fmt.Println("Paste test: focus a text field now. Pasting in 3 seconds...")
		time.Sleep(3 * time.Second)
		if err := inject.NewInjector().InsertText(context.Background(), *paste); err != nil {
			fmt.Printf("Paste test failed: %v\n", err)
		} else {
			fmt.Println("Paste test succeeded.")
		}
	}

	var presses atomic.Int64
	var releases atomic.Int64

	fmt.Printf("Hotkey test: switch to any app, hold/release %s repeatedly for %d seconds.\n", *key, *seconds)
	service := hotkey.NewService(*key)
	if err := service.Start(ctx, app.HotkeyCallbacks{
		OnPress: func() {
			n := presses.Add(1)
			fmt.Printf("[%s] press #%d\n", time.Now().Format("15:04:05.000"), n)
		},
		OnRelease: func() {
			n := releases.Add(1)
			fmt.Printf("[%s] release #%d\n", time.Now().Format("15:04:05.000"), n)
		},
	}); err != nil {
		fmt.Printf("Hotkey test failed to start: %v\n", err)
		os.Exit(1)
	}
	defer service.Stop()

	<-ctx.Done()
	fmt.Printf("Hotkey summary: presses=%d releases=%d\n", presses.Load(), releases.Load())
	if presses.Load() == 0 || releases.Load() == 0 {
		fmt.Println("Result: no complete hotkey cycle was detected.")
		os.Exit(1)
	}
	fmt.Println("Result: hotkey capture works in this process.")
}

func checkWhisper() {
	candidates := []string{
		filepath.Join("Voicy.app", "Contents", "Resources", "whisper-cli"),
		filepath.Join("bin", "whisper-cli"),
	}
	for _, candidate := range candidates {
		if info, err := os.Stat(candidate); err == nil && !info.IsDir() {
			if err := exec.Command(candidate, "--help").Run(); err != nil {
				fmt.Printf("Whisper check failed for %s: %v\n", candidate, err)
				continue
			}
			fmt.Printf("Whisper check: ok (%s)\n", candidate)
			return
		}
	}
	fmt.Println("Whisper check: no bundled/local whisper-cli found")
}

func mustExecutable() string {
	exe, err := os.Executable()
	if err != nil {
		return "(unknown)"
	}
	return exe
}
