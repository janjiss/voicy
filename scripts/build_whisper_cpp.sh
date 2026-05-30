#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WHISPER_DIR="${ROOT_DIR}/third_party/whisper.cpp"
OUTPUT_DIR="${ROOT_DIR}/bin"
OUTPUT_BIN="${OUTPUT_DIR}/whisper-cli"

mkdir -p "${OUTPUT_DIR}" "${ROOT_DIR}/third_party"

if [[ ! -d "${WHISPER_DIR}/.git" ]]; then
  git clone --depth 1 https://github.com/ggml-org/whisper.cpp.git "${WHISPER_DIR}"
else
  git -C "${WHISPER_DIR}" pull --ff-only
fi

cmake -S "${WHISPER_DIR}" -B "${WHISPER_DIR}/build" \
  -DCMAKE_BUILD_TYPE=Release \
  -DWHISPER_BUILD_TESTS=OFF \
  -DWHISPER_BUILD_EXAMPLES=ON

cmake --build "${WHISPER_DIR}/build" --config Release --target whisper-cli --parallel

if [[ -x "${WHISPER_DIR}/build/bin/whisper-cli" ]]; then
  cp "${WHISPER_DIR}/build/bin/whisper-cli" "${OUTPUT_BIN}"
elif [[ -x "${WHISPER_DIR}/build/examples/cli/whisper-cli" ]]; then
  cp "${WHISPER_DIR}/build/examples/cli/whisper-cli" "${OUTPUT_BIN}"
else
  echo "Could not find built whisper-cli binary" >&2
  exit 1
fi

chmod +x "${OUTPUT_BIN}"
bash "${ROOT_DIR}/scripts/bundle_whisper_bin_macos.sh"
echo "Built ${OUTPUT_BIN}"
