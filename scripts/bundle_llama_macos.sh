#!/usr/bin/env bash
set -euo pipefail

# Copies the statically linked llama-cli into the app bundle's Resources/ and
# ad-hoc codesigns it. Unlike whisper, llama-cli is static so there are no
# accompanying ggml dylibs to bundle.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="${ROOT_DIR}/Voicy.app"
RESOURCES_DIR="${APP_DIR}/Contents/Resources"
LLAMA_BIN="${ROOT_DIR}/bin/llama-cli"

if [[ ! -x "${LLAMA_BIN}" ]]; then
  echo "llama-cli not found at ${LLAMA_BIN}; run scripts/build_llama_cpp.sh first" >&2
  exit 1
fi

mkdir -p "${RESOURCES_DIR}"
cp "${LLAMA_BIN}" "${RESOURCES_DIR}/llama-cli"
chmod +x "${RESOURCES_DIR}/llama-cli"

if command -v install_name_tool >/dev/null 2>&1; then
  if ! otool -l "${RESOURCES_DIR}/llama-cli" | awk '
    $1 == "path" && $2 == "@loader_path" { found = 1 }
    END { exit found ? 0 : 1 }
  '; then
    install_name_tool -add_rpath "@loader_path" "${RESOURCES_DIR}/llama-cli" 2>/dev/null || true
  fi
fi

if command -v codesign >/dev/null 2>&1; then
  codesign --force --sign - "${RESOURCES_DIR}/llama-cli" >/dev/null 2>&1 || true
fi

echo "Bundled llama-cli into ${RESOURCES_DIR}"
