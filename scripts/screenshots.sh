#!/usr/bin/env bash
# Builds the app for the iOS Simulator, fills the simulator's photo library with
# sample photos and captures screenshots of the main screens into ./screenshots.
# Usage: scripts/screenshots.sh  (macOS with Xcode, after fetch-models.sh and xcodegen)
set -euo pipefail

BUNDLE_ID="io.github.alexeytatarinov.indexator"
OUT="screenshots"
mkdir -p "$OUT" sample-photos

DEVICE=$(xcrun simctl list devices available | grep -E "iPhone 16 Pro \(" | head -1 | sed -E 's/.*\(([0-9A-F-]+)\).*/\1/')
if [[ -z "$DEVICE" ]]; then
  DEVICE=$(xcrun simctl list devices available | grep -E "iPhone" | head -1 | sed -E 's/.*\(([0-9A-F-]+)\).*/\1/')
fi
echo "Simulator: $DEVICE"

xcrun simctl boot "$DEVICE" || true
xcrun simctl bootstatus "$DEVICE" -b
xcrun simctl status_bar "$DEVICE" override --time "9:41" --batteryState charged --batteryLevel 100 || true

# Sample photos (free photos from picsum.photos, fixed ids for stable results).
for id in 1003 1011 1015 1025 1035 1043 1050 1060 1062 1069 1074 1080 1084 237 200 219 169 433 582 659; do
  f="sample-photos/$id.jpg"
  [[ -s "$f" ]] || curl -fsSL --retry 3 "https://picsum.photos/id/$id/1200/900" -o "$f" || true
done
# Photos of text and a place: CLIP sees every page of text alike, so «резюме» must find
# the CV by its text and not the shopping list; «Валенсия» must show the view, not the
# documents photographed there (both carry Valencia's GPS).
VLC="39.4699 -0.3763"
swift scripts/make-text-photo.swift text sample-photos/cv-page.jpg \
  "РЕЗЮМЕ\nCV — Алексей Иванов\nCurriculum Vitae\nОпыт работы\n2019–2024 QA Engineer, Game Studio\nТестирование игр и VR, автоматизация\nОбразование: МГУ, 2015\nНавыки: Python, SQL, Jira, английский B2" $VLC || true
swift scripts/make-text-photo.swift text sample-photos/shopping-list.jpg \
  "Список покупок\nмолоко\nхлеб\nяйца 10 шт\nсыр\nпомидоры\nбананы\nвода 6 л\nстиральный порошок" $VLC || true
swift scripts/make-text-photo.swift text sample-photos/meeting-notes.jpg \
  "Заметки к встрече\n1. обсудить сроки\n2. бюджет проекта\n3. отпуск в августе\n4. позвонить в банк\n5. договор с подрядчиком" || true
[[ -s sample-photos/1050.jpg ]] && swift scripts/make-text-photo.swift copy sample-photos/valencia-view.jpg sample-photos/1050.jpg $VLC || true
ls sample-photos | wc -l
xcrun simctl addmedia "$DEVICE" sample-photos/*.jpg

# A sample video: landscape, landscape, the puppy (8-12 s), landscape. Video search
# should find it for "собака" and open it at the puppy.
mkdir -p sample-videos
swift scripts/make-sample-video.swift sample-videos/walk.mp4 4 \
  sample-photos/1015.jpg sample-photos/1043.jpg sample-photos/237.jpg sample-photos/1035.jpg || true
[[ -s sample-videos/walk.mp4 ]] && xcrun simctl addmedia "$DEVICE" sample-videos/walk.mp4 || echo "no sample video"

# Builds, installs, runs unit tests and the UI test that taps "Allow Full Access".
xcodebuild \
  -project Indexator.xcodeproj -scheme Indexator -configuration Debug \
  -sdk iphonesimulator -destination "id=$DEVICE" -derivedDataPath build-sim \
  -only-testing:IndexatorTests -only-testing:IndexatorUITests test > test.log 2>&1 \
  || { grep -E "error: |XCTAssert|failed" test.log | head -60; tail -40 test.log; exit 1; }
tail -40 test.log

shot() { # name, wait seconds, launch args...
  local name=$1 wait=$2; shift 2
  xcrun simctl terminate "$DEVICE" "$BUNDLE_ID" 2>/dev/null || true
  xcrun simctl launch "$DEVICE" "$BUNDLE_ID" "$@"
  sleep "$wait"
  xcrun simctl io "$DEVICE" screenshot "$OUT/$name.png"
  echo "Captured $name"
}

shot 1-settings-indexing 60 -uiTab settings -autoIndex YES
shot 2-home 15 -uiTab search

# Search quality: run the reference queries on the indexed sample photos and compare
# with scripts/search-eval.json (expected and forbidden photos per query).
EVAL_QUERIES=$(python3 -c 'import json;print("|".join(q["query"] for q in json.load(open("scripts/search-eval.json"))["queries"]))')
EVAL_FILE="$(xcrun simctl get_app_container "$DEVICE" "$BUNDLE_ID" data)/Documents/search-eval.json"
rm -f "$EVAL_FILE"
xcrun simctl terminate "$DEVICE" "$BUNDLE_ID" 2>/dev/null || true
xcrun simctl launch "$DEVICE" "$BUNDLE_ID" -uiTab search -docsDemo YES -mailDemo YES -searchEval "$EVAL_QUERIES"
for _ in $(seq 1 60); do [[ -s "$EVAL_FILE" ]] && break; sleep 5; done
cp "$EVAL_FILE" "$OUT/search-eval.json" || {
  echo "no eval output after 5 minutes; app log:"
  tail -40 "$(dirname "$(dirname "$EVAL_FILE")")/Library/Caches/applog.txt" || true
}
mkdir -p "$OUT/samples"
for f in sample-photos/*.jpg; do sips -Z 320 "$f" --out "$OUT/samples/$(basename "$f" .jpg).png" -s format png >/dev/null || true; done
EVAL_STATUS=0
python3 scripts/check-search-eval.py scripts/search-eval.json "$OUT/search-eval.json" > "$OUT/search-eval.txt" || EVAL_STATUS=1
cat "$OUT/search-eval.txt"
shot 3-search-grid 25 -uiTab search -autoQuery "собака"
shot 4-search-cards 25 -uiTab search -autoQuery "горы и озеро" -ui.resultLayout cards
shot 5-detail 30 -uiTab search -autoQuery "собака" -autoOpenFirst YES -autoOpenKind photo
shot 6-search-date 25 -uiTab search -autoQuery "собака 2026" -ui.resultLayout cards
shot 7-settings 15 -uiTab settings
shot 8-docs-search 30 -uiTab search -docsDemo YES -autoQuery "как вернуть налог за квартиру" -ui.resultLayout cards
shot 9-docs-search-en 30 -uiTab search -docsDemo YES -autoQuery "rent payment"
shot 10-mail-search 20 -uiTab search -mailDemo YES -autoQuery "билет на поезд" -autoMailQuery "билет на поезд" -ui.resultLayout cards
shot 11-video-search 25 -uiTab search -autoQuery "собака" -ui.resultLayout cards
shot 12-video-player 30 -uiTab search -autoQuery "собака" -autoOpenFirst YES -autoOpenKind video
shot 13-resume-no-docs 25 -uiTab search -autoQuery "моё резюме"
shot 14-scope-docs 30 -uiTab search -docsDemo YES -ui.searchScope documents -autoQuery "договор аренды"
ls -la "$OUT"
# Screenshots are taken either way; a search-quality miss still fails the job.
exit $EVAL_STATUS
