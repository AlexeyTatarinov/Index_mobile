#!/usr/bin/env bash
# Downloads MobileCLIP Core ML towers and the CLIP BPE vocabulary, compiles the
# models to .mlmodelc and puts everything into the app's Models folder.
# Usage: scripts/fetch-models.sh <cache dir> <output dir>   (macOS with Xcode)
set -euo pipefail

CACHE="${1:?cache dir}"
OUT="${2:?output dir}"
VARIANT="mobileclip_s0"
HF="https://huggingface.co/apple/coreml-mobileclip/resolve/main"
VOCAB_URL="https://openaipublic.azureedge.net/clip/bpe_simple_vocab_16e6.txt.gz"

mkdir -p "$CACHE" "$OUT"

fetch() { # url dest
  if [[ ! -s "$2" ]]; then
    mkdir -p "$(dirname "$2")"
    echo "Downloading $1"
    curl -fsSL --retry 3 "$1" -o "$2"
  fi
}

for tower in image text; do
  pkg="${VARIANT}_${tower}.mlpackage"
  for f in Manifest.json Data/com.apple.CoreML/model.mlmodel Data/com.apple.CoreML/weights/weight.bin; do
    fetch "$HF/$pkg/$f" "$CACHE/$pkg/$f"
  done
  rm -rf "$OUT/${VARIANT}_${tower}.mlmodelc"
  xcrun coremlcompiler compile "$CACHE/$pkg" "$OUT"
done

fetch "$VOCAB_URL" "$CACHE/bpe_simple_vocab_16e6.txt.gz"
gunzip -c "$CACHE/bpe_simple_vocab_16e6.txt.gz" > "$OUT/bpe_simple_vocab_16e6.txt"

du -sh "$OUT"/*
