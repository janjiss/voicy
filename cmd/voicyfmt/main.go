// Command voicyfmt is a console harness for the local LLM correction path. It
// runs the llama.cpp sidecar over a transcript (read from -text or stdin) so
// you can judge formatting/edit quality before any UI wiring is involved.
//
//	echo "um so i think we should uh ship it on friday" | go run ./cmd/voicyfmt
//	go run ./cmd/voicyfmt -model Qwen3-4B-Q4_K_M.gguf -text "..."
//	go run ./cmd/voicyfmt -selected "first thing. second thing." -edit "make this a bullet list"
package main

import (
	"context"
	"flag"
	"fmt"
	"io"
	"os"
	"strings"

	"github.com/janis/voicy/internal/llm"
	"github.com/janis/voicy/internal/models"
)

func main() {
	modelName := flag.String("model", models.DefaultLLMModelName, "LLM correction model name")
	binaryPath := flag.String("llama", "", "optional llama-cli path")
	text := flag.String("text", "", "transcript to format (otherwise read from stdin)")
	selected := flag.String("selected", "", "selected text to edit (enables edit mode)")
	edit := flag.String("edit", "", "edit instruction to apply to -selected")
	flag.Parse()

	ctx := context.Background()
	manager, err := models.NewManager("Voicy")
	if err != nil {
		exitErr("create model manager", err)
	}

	fmt.Fprintf(os.Stderr, "Ensuring model: %s\n", *modelName)
	lastPercent := -1
	if _, err := manager.Ensure(ctx, *modelName, func(downloaded, total int64) {
		if total <= 0 {
			return
		}
		percent := int(float64(downloaded) * 100 / float64(total))
		if percent != lastPercent {
			lastPercent = percent
			fmt.Fprintf(os.Stderr, "\rDownloading model: %d%%", percent)
		}
	}); err != nil {
		fmt.Fprintln(os.Stderr)
		exitErr("ensure model", err)
	}
	if lastPercent >= 0 {
		fmt.Fprintln(os.Stderr)
	}

	client := llm.NewClient(manager, *modelName, *binaryPath)

	if *edit != "" {
		out, err := client.Edit(ctx, *selected, *edit)
		if err != nil {
			exitErr("edit", err)
		}
		fmt.Println(out)
		return
	}

	input := *text
	if input == "" {
		data, _ := io.ReadAll(os.Stdin)
		input = strings.TrimSpace(string(data))
	}
	if input == "" {
		fmt.Fprintln(os.Stderr, "no input: pass -text or pipe a transcript on stdin")
		os.Exit(1)
	}

	out, err := client.Format(ctx, input)
	if err != nil {
		exitErr("format", err)
	}
	fmt.Println(out)
}

func exitErr(stage string, err error) {
	fmt.Fprintf(os.Stderr, "Error during %s: %v\n", stage, err)
	os.Exit(1)
}
