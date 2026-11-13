# Importing a Bible translation

Transcribe includes public-domain translations only (KJV, WEB, BSB, ASV, YLT). Other versions (NIV, ESV, NLT, NKJV, NASB, CSB, AMP, MSG…) are copyrighted and can't be included. To use one, your church must be licensed for it. Then either:

- **Import a licensed copy** in **Settings › Translations › Import Translation…**. Supported formats: OSIS XML, USFM (one file, several files, or a folder with one book per file), USX, Zefania XML, the JSON format below, or the SQLite format below. Transcribe shows what it found (books, verses, any problems) and asks for the abbreviation, name and licence before installing.
- **Connect an online provider** with your own key in **Settings › Translations**: the ESV API (Crossway) for ESV, or API.Bible for the versions your key is licensed for. Keys are kept in the Keychain. Fetched passages are cached on this Mac only as each provider's terms allow (ESV: at most 500 verses; API.Bible: refreshed at least every 30 days), and the provider's copyright notice is shown with the text.

When a speaker names a version that isn't available, the verse is shown in your default translation, labelled for example “NIV requested, showing KJV”, with a **Get NIV…** button that opens these settings.

Imported files are stored in `~/Library/Containers/app.transcribe.Transcribe/Data/Library/Application Support/Transcribe/Translations/`.

## What the importers read

| Format | Verses | Skipped | Metadata used |
| --- | --- | --- | --- |
| OSIS | `<verse osisID="John.3.16">…</verse>` and milestones (`sID`/`eID`) | `<note>`, `<title>` | `osisIDWork`, header `<title>`, `<rights>` |
| USFM | `\c` / `\v` (bridged verses like `\v 17-18` use the first number) | footnotes `\f…\f*`, cross references `\x…\x*`, headings (`\s`, `\mt`, `\h`, `\toc`…), introductions, word attributes (`\w word|strong="…"\w*` keeps “word”) | none (enter it when importing) |
| USX | `<verse number>` with or without `eid` | `<note>`, heading paragraphs (`s`, `mt`, `h`…) | none |
| Zefania XML | `<BIBLEBOOK bnumber><CHAPTER cnumber><VERS vnumber>` | `<NOTE>`, `<DIV>`, `<XREF>` | `biblename`, `<title>`, `<identifier>`, `<rights>` |

Books outside the 66-book Protestant canon (deuterocanonical books, front matter) are skipped with a note. Files with no verses, unknown book codes, or broken XML are rejected with the file name and line.

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
