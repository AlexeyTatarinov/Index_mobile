# SPDX-License-Identifier: GPL-3.0-or-later
#
# Compares the app's search results (Documents/search-eval.json from the simulator)
# with the expectations in scripts/search-eval.json. Prints a table; exits 1 on misses.
# Usage: python3 check-search-eval.py <expectations.json> <results.json>

import json
import sys

expected = {q["query"]: q for q in json.load(open(sys.argv[1]))["queries"]}
try:
    got = json.load(open(sys.argv[2]))
except (OSError, ValueError) as error:
    print(f"no results: {error}")
    sys.exit(1)

failures = 0
for row in got["queries"]:
    q = expected.get(row["query"], {})
    files = [h["file"] for h in row["hits"]]
    shown = ", ".join(f'{h["file"].replace(".jpg", "")} {h["score"]:.2f}/{h.get("adj", 0):+.3f}{"T" if h["text"] else ""}' for h in row["hits"][:10])
    near = ", ".join(f'{h["file"].replace(".jpg", "")} {h["adj"]:+.3f}' for h in row.get("near", []))
    problems = []
    within = q.get("within", 10)
    for f in q.get("expect", []):
        if f not in files[:within]:
            problems.append(f"{f} not in top {within}")
    for f in q.get("forbid", []):
        if f in files:
            problems.append(f"{f} should not be found")
    if q.get("empty") and files:
        problems.append(f"expected nothing, got {len(files)}")
    docs = row.get("docs", [])
    mail = row.get("mail", [])
    for f in q.get("docs", []):
        if f not in docs[:q.get("docsWithin", 3)]:
            problems.append(f"document {f} not in top {q.get('docsWithin', 3)}")
    for f in q.get("docsForbid", []):
        if f in docs:
            problems.append(f"document {f} should not be found")
    for m in q.get("mail", []):
        if m not in mail[:3]:
            problems.append(f"email {m} not in top 3")
    for m in q.get("mailForbid", []):
        if m in mail:
            problems.append(f"email {m} should not be found")
    videos = row.get("videos", 0)
    if "videos" in q and videos != q["videos"]:
        problems.append(f"expected {q['videos']} videos, got {videos}")
    failures += bool(problems)
    mark = "FAIL" if problems else "ok  "
    print(f"{mark} «{row['query']}» [{len(files)}, videos {row.get('videos', 0)} top {row.get('videoTop', 0):+.3f}] {shown}")
    if problems:
        print("     " + "; ".join(problems))
    if docs or mail:
        print(f"     docs: {', '.join(docs[:5]) or '-'} · mail: {', '.join(mail[:5]) or '-'}")
    print("     " + row["info"])
    if near:
        print("     ranked by adjusted score: " + near)

print()
print("Scene labels per sample photo:")
for name, labels in sorted(got.get("photos", {}).items()):
    print(f"  {name}: {', '.join(labels)}")

print(f"\n{len(got['queries']) - failures}/{len(got['queries'])} queries as expected")
sys.exit(1 if failures else 0)
