#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
NPROC=$(sysctl -n hw.logicalcpu)

echo "=== Building whisper.cpp ==="
cd "$PROJECT_DIR/Libraries/whisper.cpp"
cmake -B build \
    -DCMAKE_BUILD_TYPE=Release \
    -DGGML_METAL=ON \
    -DBUILD_SHARED_LIBS=OFF \
    -DWHISPER_BUILD_EXAMPLES=OFF \
    -DWHISPER_BUILD_TESTS=OFF \
    -DCMAKE_OSX_ARCHITECTURES=arm64
cmake --build build --config Release -j "$NPROC"

echo "=== Building llama.cpp ==="
cd "$PROJECT_DIR/Libraries/llama.cpp"
cmake -B build \
    -DCMAKE_BUILD_TYPE=Release \
    -DGGML_METAL=ON \
    -DBUILD_SHARED_LIBS=OFF \
    -DLLAMA_BUILD_EXAMPLES=OFF \
    -DLLAMA_BUILD_TESTS=OFF \
    -DLLAMA_BUILD_SERVER=OFF \
    -DCMAKE_OSX_ARCHITECTURES=arm64
cmake --build build --config Release -j "$NPROC"

echo "=== Build complete ==="
echo "Whisper libs:"
find "$PROJECT_DIR/Libraries/whisper.cpp/build" -name "*.a" | head -20
echo "Llama libs:"
find "$PROJECT_DIR/Libraries/llama.cpp/build" -name "*.a" | head -20
