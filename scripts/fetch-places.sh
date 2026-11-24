#!/usr/bin/env bash
# Downloads GeoNames cities with population >= 15000 (CC BY 4.0) and builds the
# app's offline places table. Usage: scripts/fetch-places.sh <cache dir> <output dir>
set -euo pipefail

CACHE="${1:?cache dir}"
OUT="${2:?output dir}"
HERE="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$CACHE" "$OUT"

if [[ ! -s "$CACHE/places.tsv" ]]; then
  curl -fsSL --retry 3 https://download.geonames.org/export/dump/cities15000.zip -o "$CACHE/cities15000.zip"
  unzip -o -q "$CACHE/cities15000.zip" -d "$CACHE"
  python3 -I "$HERE/build-places.py" "$CACHE/cities15000.txt" "$CACHE/places.tsv"
  rm -f "$CACHE/cities15000.zip" "$CACHE/cities15000.txt"
fi
cp "$CACHE/places.tsv" "$OUT/places.tsv"
du -sh "$OUT/places.tsv"
