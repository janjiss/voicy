package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"time"

	"github.com/janis/voicy/internal/audio"
	"github.com/janis/voicy/internal/models"
	texttransform "github.com/janis/voicy/internal/text"
	"github.com/janis/voicy/internal/transcribe"
)

func main() {
	seconds := flag.Int("seconds", 5, "seconds to record")
	modelName := flag.String("model", models.DefaultModelName, "Whisper model name")
	binaryPath := flag.String("whisper", "", "optional whisper-cli path")
	keepAudio := flag.Bool("keep-audio", false, "keep the temporary WAV file")
	flag.Parse()

	if *seconds <= 0 {
		fmt.Fprintln(os.Stderr, "seconds must be greater than zero")
		os.Exit(1)
	}

	ctx := context.Background()
	recorder := audio.NewRecorder()

	fmt.Printf("Voicy console transcription\n")
	fmt.Printf("Recording for %d seconds. Speak now...\n", *seconds)

	if err := recorder.Start(ctx); err != nil {
		exitErr("start recording", err)
	}

	for remaining := *seconds; remaining > 0; remaining-- {
		fmt.Printf("  %d...\n", remaining)
		time.Sleep(time.Second)
	}

	audioPath, err := recorder.Stop(ctx)
	if err != nil {
		exitErr("stop recording", err)
	}
	if !*keepAudio {
		defer os.Remove(audioPath)
	}
	fmt.Printf("Audio captured: %s\n", audioPath)

	manager, err := models.NewManager("Voicy")
	if err != nil {
		exitErr("create model manager", err)
	}

	fmt.Printf("Ensuring model: %s\n", *modelName)
	lastPercent := -1
	if _, err := manager.Ensure(ctx, *modelName, func(downloaded, total int64) {
		if total <= 0 {
			fmt.Printf("\rDownloaded %d bytes", downloaded)
			return
		}
		percent := int(float64(downloaded) * 100 / float64(total))
		if percent != lastPercent {
			lastPercent = percent
			fmt.Printf("\rDownloading model: %d%%", percent)
		}
	}); err != nil {
		fmt.Println()
		exitErr("ensure model", err)
	}
	if lastPercent >= 0 {
		fmt.Println()
	}

	fmt.Println("Transcribing...")
	whisper := transcribe.NewWhisper(manager, *modelName, *binaryPath)
	transcript, err := whisper.Transcribe(ctx, audioPath)
	if err != nil {
		exitErr("transcribe", err)
	}

	transcript = texttransform.NewTransformer().CleanupTranscript(transcript)
	fmt.Println()
	fmt.Println("Transcript:")
	fmt.Println(transcript)
}

func exitErr(stage string, err error) {
	fmt.Fprintf(os.Stderr, "Error during %s: %v\n", stage, err)
	os.Exit(1)
}
