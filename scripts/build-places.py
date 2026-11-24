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
RUSSIAN = re.compile(r"^[А-Яа-яЁё \-]+$")  # Russian letters only, not Serbian or Ukrainian


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
        names, russian_options = [], []
        for candidate in [name, ascii_name] + alternates:
            if not candidate or not LATIN_OR_CYRILLIC.match(candidate):
                continue
            if RUSSIAN.match(candidate):
                russian_options.append(candidate)
            n = norm(candidate)
            if len(n) >= 3 and n not in names:
                names.append(n)
        # GeoNames does not tag languages; a single word, then the longest spelling,
        # picks «Валенсия» over the case form «Валенси».
        russian = ""
        if russian_options:
            single = [r for r in russian_options if " " not in r and "-" not in r] or russian_options
            russian = max(single, key=len)
        if not names:
            continue
        out.write("\t".join([lat, lon, population, country, name, russian, "|".join(names)]) + "\n")
        rows += 1
print(f"places: {rows}")
