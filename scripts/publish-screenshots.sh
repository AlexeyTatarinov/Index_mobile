#!/usr/bin/env bash
# Commits ./screenshots/*.png to the `screenshots` branch under <source branch>/,
# and regenerates that branch's README so the images can be browsed on GitHub.
set -euo pipefail

SRC="${GITHUB_HEAD_REF:-${GITHUB_REF_NAME:-local}}"
SRC="${SRC//\//-}"
WT=shots-wt

git config --global user.name "github-actions[bot]"
git config --global user.email "41898282+github-actions[bot]@users.noreply.github.com"

if git fetch --depth 1 origin screenshots 2>/dev/null; then
  git worktree add "$WT" FETCH_HEAD
  (cd "$WT" && git checkout -B screenshots)
else
  git worktree add --orphan -b screenshots "$WT"
fi

rm -rf "$WT/$SRC"
mkdir -p "$WT/$SRC"
cp screenshots/*.png "$WT/$SRC/"

{
  echo "# Скриншоты из симулятора"
  echo
  echo "Обновляются автоматически при каждой сборке. Папка = ветка."
  for dir in $(cd "$WT" && ls -d */ | sed 's#/##' | sort); do
    echo
    echo "## $dir"
    echo
    for img in $(cd "$WT/$dir" && ls *.png | sort); do
      echo "<img src=\"$dir/$img\" width=\"260\" alt=\"$img\">"
    done
  done
} > "$WT/README.md"

cd "$WT"
git add -A
if git diff --cached --quiet; then
  echo "No changes"
  exit 0
fi
git commit -q -m "Screenshots for $SRC (${GITHUB_SHA:-local})"
for i in 1 2 3; do
  git push origin screenshots && exit 0
  git pull --rebase origin screenshots || true
done
exit 1
