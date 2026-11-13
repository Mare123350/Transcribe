#!/usr/bin/env python3
"""Builds the bundled public-domain Bible databases (Transcribe/Resources/Bibles/*.sqlite).

Sources (all public domain):
  KJV, WEB  - USFM-keyed JSON: {"books": {"GEN": [[verse, ...], ...], ...}}
  ASV, YLT, BSB - scrollmapper/bible_databases formats/json/<V>.json (66 books in canonical order)

Usage: python3 -I Tools/build_bibles.py <kjv.json> <web.json> <ASV.json> <YLT.json> <BSB.json> <out-dir>

The output schema is the same one users import (see docs/TRANSLATION_FORMAT.md).
"""
import json, os, sqlite3, sys

CANON = ("GEN EXO LEV NUM DEU JOS JDG RUT 1SA 2SA 1KI 2KI 1CH 2CH EZR NEH EST JOB PSA PRO ECC SNG ISA JER LAM "
         "EZK DAN HOS JOL AMO OBA JON MIC NAM HAB ZEP HAG ZEC MAL MAT MRK LUK JHN ACT ROM 1CO 2CO GAL EPH PHP COL "
         "1TH 2TH 1TI 2TI TIT PHM HEB JAS 1PE 2PE 1JN 2JN 3JN JUD REV").split()

META = {
    "kjv": ("KJV", "King James Version"),
    "web": ("WEB", "World English Bible"),
    "asv": ("ASV", "American Standard Version (1901)"),
    "ylt": ("YLT", "Young's Literal Translation (1898)"),
    "bsb": ("BSB", "Berean Standard Bible"),
}

def usfm_rows(path):
    books = json.load(open(path))["books"]
    for book, chapters in books.items():
        for c, verses in enumerate(chapters, 1):
            for v, text in enumerate(verses, 1):
                yield book, c, v, text

def scrollmapper_rows(path):
    books = json.load(open(path))["books"]
    assert len(books) == 66, path
    for book, data in zip(CANON, books):
        for chapter in data["chapters"]:
            for verse in chapter["verses"]:
                yield book, chapter["chapter"], verse["verse"], verse["text"]

def write(out_dir, vid, rows):
    abbr, name = META[vid]
    path = os.path.join(out_dir, f"{vid}.sqlite")
    if os.path.exists(path):
        os.remove(path)
    db = sqlite3.connect(path)
    db.executescript("""
        CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
        CREATE TABLE verses(book TEXT NOT NULL, chapter INTEGER NOT NULL, verse INTEGER NOT NULL, text TEXT NOT NULL,
                            PRIMARY KEY(book, chapter, verse)) WITHOUT ROWID;
    """)
    db.executemany("INSERT INTO meta VALUES (?, ?)", [
        ("id", vid), ("abbreviation", abbr), ("name", name), ("license", "Public domain"), ("schema_version", "1")])
    clean = ((b, c, v, " ".join(t.replace("`", "'").split())) for b, c, v, t in rows if t.strip())
    db.executemany("INSERT OR REPLACE INTO verses VALUES (?, ?, ?, ?)", clean)
    db.commit()
    db.execute("VACUUM")
    count = db.execute("SELECT count(*) FROM verses").fetchone()[0]
    db.close()
    print(f"{vid}: {count} verses -> {path}")

if __name__ == "__main__":
    kjv, web, asv, ylt, bsb, out = sys.argv[1:7]
    os.makedirs(out, exist_ok=True)
    write(out, "kjv", usfm_rows(kjv))
    write(out, "web", usfm_rows(web))
    write(out, "asv", scrollmapper_rows(asv))
    write(out, "ylt", scrollmapper_rows(ylt))
    write(out, "bsb", scrollmapper_rows(bsb))
