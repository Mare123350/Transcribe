# Importing a Bible translation

Transcribe bundles public-domain translations only (KJV, WEB, BSB, ASV, YLT). To use another version, your church must be licensed for it. Import it in **Settings › Scripture › Import Translation…** as SQLite or JSON. Imported files are stored in `~/Library/Containers/app.transcribe.Transcribe/Data/Library/Application Support/Transcribe/Translations/`.

Book identifiers are [USFM codes](https://ubsicap.github.io/usfm/identification/books.html): `GEN`, `EXO`, … `MAT`, `MRK`, `LUK`, `JHN`, `ACT`, `ROM`, `1CO`, `2CO`, … `REV`.

## SQLite

```sql
CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE verses(
  book    TEXT    NOT NULL,   -- USFM code, e.g. 'JHN'
  chapter INTEGER NOT NULL,
  verse   INTEGER NOT NULL,
  text    TEXT    NOT NULL,
  PRIMARY KEY(book, chapter, verse)
) WITHOUT ROWID;
```

`meta` keys:

| key | example | required |
| --- | --- | --- |
| `id` | `niv` | yes (lowercase, unique) |
| `abbreviation` | `NIV` | yes (shown on screen) |
| `name` | `New International Version` | yes |
| `license` | `Licensed to Grace Church, CCLI #…` | recommended |
| `schema_version` | `1` | optional |

## JSON

```json
{
  "id": "niv",
  "abbreviation": "NIV",
  "name": "New International Version",
  "license": "Licensed to Grace Church",
  "verses": [
    { "book": "JHN", "chapter": 3, "verse": 16, "text": "For God so loved the world…" }
  ]
}
```

`book` may also be a book name such as `"John"` or `"1 Corinthians"`. JSON imports are converted to SQLite.

Missing verses are fine: a passage that isn't in the file simply isn't offered in that version.
