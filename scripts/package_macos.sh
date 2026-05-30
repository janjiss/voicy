#!/usr/bin/env bash
set -euo pipefail

# Assembles Voicy.app: a native Swift menu-bar frontend that spawns the headless
# Go backend helper and talks to it over the stdio JSON protocol.
#
#   Voicy.app/Contents/
#     Info.plist
#     MacOS/Voicy           native Swift frontend (bundle main executable)
#     MacOS/voicy-backend   headless Go backend helper
#     Resources/whisper-cli + dylibs (added by bundle_whisper_macos.sh)

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="${ROOT_DIR}/Voicy.app"
MACOS_DIR="${APP_DIR}/Contents/MacOS"
RESOURCES_DIR="${APP_DIR}/Contents/Resources"
APP_VERSION="${APP_VERSION:-0.1.0}"

rm -rf "${APP_DIR}"
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}"

echo "Building Go backend helper..."
( cd "${ROOT_DIR}" && go build -o "${MACOS_DIR}/voicy-backend" ./cmd/voicy )

echo "Building Swift frontend..."
( cd "${ROOT_DIR}/macos" && swift build -c release )
cp "${ROOT_DIR}/macos/.build/release/Voicy" "${MACOS_DIR}/Voicy"
chmod +x "${MACOS_DIR}/Voicy" "${MACOS_DIR}/voicy-backend"

cat > "${APP_DIR}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Voicy</string>
    <key>CFBundleDisplayName</key>
    <string>Voicy</string>
    <key>CFBundleIdentifier</key>
    <string>com.voicy.app</string>
    <key>CFBundleExecutable</key>
    <string>Voicy</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${APP_VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${APP_VERSION}</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>Voicy records short clips to transcribe your speech into text.</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

# Optional app icon: convert Icon.png -> AppIcon.icns when tooling is available.
if [[ -f "${ROOT_DIR}/Icon.png" ]] && command -v sips >/dev/null 2>&1 && command -v iconutil >/dev/null 2>&1; then
  ICONSET="$(mktemp -d)/AppIcon.iconset"
  mkdir -p "${ICONSET}"
  for size in 16 32 64 128 256 512; do
    sips -z "${size}" "${size}" "${ROOT_DIR}/Icon.png" --out "${ICONSET}/icon_${size}x${size}.png" >/dev/null 2>&1 || true
    double=$((size * 2))
    sips -z "${double}" "${double}" "${ROOT_DIR}/Icon.png" --out "${ICONSET}/icon_${size}x${size}@2x.png" >/dev/null 2>&1 || true
  done
  if iconutil -c icns "${ICONSET}" -o "${RESOURCES_DIR}/AppIcon.icns" >/dev/null 2>&1; then
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "${APP_DIR}/Contents/Info.plist" >/dev/null 2>&1 || true
  fi
fi

echo "Assembled ${APP_DIR}"
