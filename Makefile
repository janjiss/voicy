APP_NAME := Voicy
BACKEND := dist/voicy-backend
ICON := $(CURDIR)/Icon.png
WHISPER_BIN := bin/whisper-cli

.PHONY: run backend frontend rec check build test tidy whisper macos-app package-macos clean

# Dev run: build the Go backend, then launch the Swift frontend pointed at it
# via the VOICY_BACKEND override so no .app bundle is required.
run: backend
	cd macos && VOICY_BACKEND=$(CURDIR)/$(BACKEND) swift run

backend:
	mkdir -p dist
	go build -o $(BACKEND) ./cmd/voicy

frontend:
	cd macos && swift build

rec:
	go run ./cmd/voicyrec

check:
	go run ./cmd/voicycheck

build:
	mkdir -p dist
	go build -o $(BACKEND) ./cmd/voicy
	go build -o dist/voicycheck ./cmd/voicycheck
	go build -o dist/voicyrec ./cmd/voicyrec

test:
	go test ./...

tidy:
	go mod tidy
	gofmt -w cmd internal

Icon.png:
	go run ./tools/icon

$(WHISPER_BIN):
	bash scripts/build_whisper_cpp.sh

whisper: $(WHISPER_BIN)
	bash scripts/bundle_whisper_bin_macos.sh

# Assemble the native macOS app (Swift frontend + Go backend helper).
macos-app:
	bash scripts/package_macos.sh

package-macos: Icon.png $(WHISPER_BIN)
	bash scripts/bundle_whisper_bin_macos.sh
	bash scripts/package_macos.sh
	bash scripts/bundle_whisper_macos.sh

clean:
	rm -rf dist $(APP_NAME).app
	cd macos && rm -rf .build
