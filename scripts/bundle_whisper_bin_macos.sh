#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN_DIR="${ROOT_DIR}/bin"
WHISPER_BUILD_DIR="${ROOT_DIR}/third_party/whisper.cpp/build"

mkdir -p "${BIN_DIR}"

copy_dylib_family() {
  local dir="$1"
  local pattern="$2"

  find "${dir}" -maxdepth 1 \( -type f -o -type l \) -name "${pattern}" -exec cp -a {} "${BIN_DIR}/" \;
}

copy_dylib_family "${WHISPER_BUILD_DIR}/src" "libwhisper*.dylib"
copy_dylib_family "${WHISPER_BUILD_DIR}/ggml/src" "libggml*.dylib"
copy_dylib_family "${WHISPER_BUILD_DIR}/ggml/src/ggml-blas" "libggml-blas*.dylib"
copy_dylib_family "${WHISPER_BUILD_DIR}/ggml/src/ggml-metal" "libggml-metal*.dylib"

add_rpath_if_missing() {
  local binary="$1"
  local rpath="$2"

  if ! otool -l "${binary}" | awk '
    $1 == "path" && $2 == rpath { found = 1 }
    END { exit found ? 0 : 1 }
  ' rpath="${rpath}"; then
    install_name_tool -add_rpath "${rpath}" "${binary}"
  fi
}

add_rpath_if_missing "${BIN_DIR}/whisper-cli" "@loader_path"

while IFS= read -r -d '' dylib; do
  add_rpath_if_missing "${dylib}" "@loader_path"
done < <(find "${BIN_DIR}" -type f -name "*.dylib" -print0)

if command -v codesign >/dev/null 2>&1; then
  codesign --force --sign - "${BIN_DIR}/whisper-cli" >/dev/null 2>&1 || true
  while IFS= read -r -d '' dylib; do
    codesign --force --sign - "${dylib}" >/dev/null 2>&1 || true
  done < <(find "${BIN_DIR}" -type f -name "*.dylib" -print0)
fi

echo "Bundled whisper-cli dylibs into ${BIN_DIR}"
