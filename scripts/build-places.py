# SPDX-License-Identifier: GPL-3.0-or-later
#
# Turns GeoNames cities15000.txt into a compact places.tsv for the app:
#   lat  lon  population  country  english name  russian name  search names (|-separated)
# Search names are lowercased Latin and Cyrillic spellings, so «Валенсия» and
# "Valencia" both find the same city. Usage: python3 build-places.py <in.txt> <out.tsv>

import re
import sys

LATIN_OR_CYRILLIC = re.compile(r"^[A-Za-zÀ-ɏЀ-ӿ' .\-]+$")
CYRILLIC = re.compile(r"[Ѐ-ӿ]")


def norm(s):
    return re.sub(r"\s+", " ", s.lower().replace("ё", "е").replace("-", " ").replace("'", "")).strip()


rows = 0
with open(sys.argv[1], encoding="utf-8") as src, open(sys.argv[2], "w", encoding="utf-8") as out:
    for line in src:
        f = line.rstrip("\n").split("\t")
        if len(f) < 15:
            continue
        name, ascii_name, alternates = f[1], f[2], f[3].split(",") if f[3] else []
        lat, lon, country, population = f[4], f[5], f[8], f[14] or "0"
        names, russian = [], ""
        for candidate in [name, ascii_name] + alternates:
            if not candidate or not LATIN_OR_CYRILLIC.match(candidate):
                continue
            if not russian and CYRILLIC.search(candidate) and not re.search(r"[іїєґўћђљњџ]", candidate.lower()):
                russian = candidate
            n = norm(candidate)
            if len(n) >= 3 and n not in names:
                names.append(n)
        if not names:
            continue
        out.write("\t".join([lat, lon, population, country, name, russian, "|".join(names[:40])]) + "\n")
        rows += 1
print(f"places: {rows}")
