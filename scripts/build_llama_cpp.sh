#!/usr/bin/env bash
set -euo pipefail

# Builds a statically linked llama-cli from llama.cpp. Static linking keeps the
# llama sidecar self-contained so its ggml libraries can't collide with the ones
# whisper.cpp bundles into the same Resources/ directory.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LLAMA_DIR="${ROOT_DIR}/third_party/llama.cpp"
OUTPUT_DIR="${ROOT_DIR}/bin"
OUTPUT_BIN="${OUTPUT_DIR}/llama-cli"

mkdir -p "${OUTPUT_DIR}" "${ROOT_DIR}/third_party"

if [[ ! -d "${LLAMA_DIR}/.git" ]]; then
  git clone --depth 1 https://github.com/ggml-org/llama.cpp.git "${LLAMA_DIR}"
else
  git -C "${LLAMA_DIR}" pull --ff-only
fi

cmake -S "${LLAMA_DIR}" -B "${LLAMA_DIR}/build" \
  -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_SHARED_LIBS=OFF \
  -DLLAMA_BUILD_TESTS=OFF \
  -DLLAMA_BUILD_EXAMPLES=OFF \
  -DLLAMA_BUILD_TOOLS=ON \
  -DLLAMA_CURL=OFF

cmake --build "${LLAMA_DIR}/build" --config Release --target llama-cli --parallel

if [[ -x "${LLAMA_DIR}/build/bin/llama-cli" ]]; then
  cp "${LLAMA_DIR}/build/bin/llama-cli" "${OUTPUT_BIN}"
else
  echo "Could not find built llama-cli binary" >&2
  exit 1
fi

chmod +x "${OUTPUT_BIN}"
echo "Built ${OUTPUT_BIN}"
