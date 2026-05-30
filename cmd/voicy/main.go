package main

import (
	"context"
	"log"
	"os/signal"
	"syscall"

	"github.com/janis/voicy/internal/runtime"
)

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	if err := runtime.Run(ctx); err != nil {
		log.Fatal(err)
	}
}
