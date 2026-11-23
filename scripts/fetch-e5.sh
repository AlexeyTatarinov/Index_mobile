#!/usr/bin/env bash
# Converts intfloat/multilingual-e5-small to Core ML (once, cached), compiles it
# to .mlmodelc and puts it with the tokenizer and test references into the app's
# Models folder.
# Usage: scripts/fetch-e5.sh <cache dir> <output dir>   (macOS with Xcode and python3)
set -euo pipefail

CACHE="${1:?cache dir}"
OUT="${2:?output dir}"
HERE="$(cd "$(dirname "$0")" && pwd)"
PKG="multilingual_e5_small.mlpackage"
E5="$CACHE/e5"

mkdir -p "$CACHE" "$OUT"

if [[ ! -d "$E5/$PKG" || ! -s "$E5/e5_tokenizer.json" || ! -s "$E5/e5_reference.json" ]]; then
  echo "Converting multilingual-e5-small to Core ML"
  VENV="$CACHE/venv-e5"
  python3 -m venv "$VENV"
  "$VENV/bin/pip" install --quiet --upgrade pip
  "$VENV/bin/pip" install --quiet -r "$HERE/requirements-e5.txt"
  rm -rf "$E5"
  "$VENV/bin/python" "$HERE/convert-e5.py" "$E5"
  # Only the converted files are worth caching.
  rm -rf "$VENV"
fi

rm -rf "$OUT/multilingual_e5_small.mlmodelc"
xcrun coremlcompiler compile "$E5/$PKG" "$OUT"
cp "$E5/e5_tokenizer.json" "$E5/e5_reference.json" "$OUT/"

du -sh "$OUT"/multilingual_e5_small.mlmodelc "$OUT"/e5_*.json
