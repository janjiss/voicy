#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="${ROOT_DIR}/Voicy.app"
RESOURCES_DIR="${APP_DIR}/Contents/Resources"
WHISPER_BUILD_DIR="${ROOT_DIR}/third_party/whisper.cpp/build"

mkdir -p "${RESOURCES_DIR}"

cp "${ROOT_DIR}/bin/whisper-cli" "${RESOURCES_DIR}/whisper-cli"
chmod +x "${RESOURCES_DIR}/whisper-cli"

copy_dylib_family() {
  local dir="$1"
  local pattern="$2"

  find "${dir}" -maxdepth 1 \( -type f -o -type l \) -name "${pattern}" -exec cp -a {} "${RESOURCES_DIR}/" \;
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

add_rpath_if_missing "${RESOURCES_DIR}/whisper-cli" "@executable_path"
add_rpath_if_missing "${RESOURCES_DIR}/whisper-cli" "@loader_path"

while IFS= read -r -d '' dylib; do
  add_rpath_if_missing "${dylib}" "@loader_path"
done < <(find "${RESOURCES_DIR}" -type f -name "*.dylib" -print0)

if command -v codesign >/dev/null 2>&1; then
  codesign --force --sign - "${RESOURCES_DIR}/whisper-cli" >/dev/null 2>&1 || true
  while IFS= read -r -d '' dylib; do
    codesign --force --sign - "${dylib}" >/dev/null 2>&1 || true
  done < <(find "${RESOURCES_DIR}" -type f -name "*.dylib" -print0)
fi

echo "Bundled whisper-cli and dylibs into ${RESOURCES_DIR}"
