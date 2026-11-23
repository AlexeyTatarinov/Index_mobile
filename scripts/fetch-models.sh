#!/usr/bin/env bash
# Builds the multilingual CLIP Core ML towers (once, cached), compiles them to
# .mlmodelc and puts them with the tokenizer vocabulary into the app's Models folder.
# Usage: scripts/fetch-models.sh <cache dir> <output dir>   (macOS with Xcode and python3)
set -euo pipefail

CACHE="${1:?cache dir}"
OUT="${2:?output dir}"
VARIANT="mclip_b32"
HERE="$(cd "$(dirname "$0")" && pwd)"

mkdir -p "$CACHE" "$OUT"

if [[ ! -d "$CACHE/${VARIANT}_image.mlpackage" || ! -d "$CACHE/${VARIANT}_text.mlpackage" || ! -s "$CACHE/${VARIANT}_vocab.txt" ]]; then
  python3 -m venv "$CACHE/venv"
  "$CACHE/venv/bin/pip" install -q -r "$HERE/requirements-convert.txt"
  "$CACHE/venv/bin/python" "$HERE/convert-mclip.py" "$CACHE"
  rm -rf "$CACHE/venv"
fi

for tower in image text; do
  rm -rf "$OUT/${VARIANT}_${tower}.mlmodelc"
  xcrun coremlcompiler compile "$CACHE/${VARIANT}_${tower}.mlpackage" "$OUT"
done
cp "$CACHE/${VARIANT}_vocab.txt" "$CACHE/${VARIANT}_tokens.json" "$OUT/"

du -sh "$OUT"/*
