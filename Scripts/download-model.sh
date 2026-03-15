#!/bin/bash
set -euo pipefail

# Model download script for Vox Populi
# Downloads Whisper GGML models from HuggingFace

BASE_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main"
AVAILABLE_MODELS="tiny base small medium large-v3"
MODEL_DIR="$HOME/Library/Application Support/VoxPopuli/models"

get_url() {
    case "$1" in
        tiny)      echo "$BASE_URL/ggml-tiny.bin" ;;
        base)      echo "$BASE_URL/ggml-base.bin" ;;
        small)     echo "$BASE_URL/ggml-small.bin" ;;
        medium)    echo "$BASE_URL/ggml-medium.bin" ;;
        large-v3)  echo "$BASE_URL/ggml-large-v3.bin" ;;
        *)         return 1 ;;
    esac
}

if [ $# -lt 1 ]; then
    echo "Usage: $0 <model-name>"
    echo "Available models: $AVAILABLE_MODELS"
    exit 1
fi

MODEL_NAME="$1"

URL=$(get_url "$MODEL_NAME" 2>/dev/null) || {
    echo "Error: Unknown model '$MODEL_NAME'"
    echo "Available models: $AVAILABLE_MODELS"
    exit 1
}

FILENAME="ggml-${MODEL_NAME}.bin"
DEST="$MODEL_DIR/$FILENAME"

mkdir -p "$MODEL_DIR"

if [ -f "$DEST" ]; then
    echo "Model already exists: $DEST"
    echo "Delete it first if you want to re-download."
    exit 0
fi

echo "Downloading $MODEL_NAME model..."
echo "  URL: $URL"
echo "  Destination: $DEST"
curl -L --progress-bar -o "$DEST" "$URL"

echo "Download complete: $DEST"
ls -lh "$DEST"
