# Importing songs

Open the **Song Library** (⇧⌘L) and press **Import**. Several files can be imported at once. Modern worship songs are copyrighted: only import songs your church is licensed to use (for example under CCLI).

## JSON

One song, an array of songs, or `{"songs": [...]}`:

```json
{
  "title": "Amazing Grace",
  "artist": "John Newton",
  "sections": [
    { "name": "Verse 1", "lyrics": "Amazing grace! How sweet the sound\nThat saved a wretch like me!" },
    { "name": "Chorus",  "lyrics": "…" }
  ]
}
```

The library can be exported in the same format.

## Plain text

```
Amazing Grace
Artist: John Newton

[Verse 1]
Amazing grace! How sweet the sound
That saved a wretch like me!

Chorus:
…
```

- The first line is the title. An optional `Artist:` (or `By …`) line follows.
- Headings such as `[Verse 1]`, `Chorus:`, `BRIDGE`, `Pre-Chorus`, `Tag` start sections.
- Without headings, blank lines separate sections; a block that appears more than once becomes the chorus.
- Put several songs in one file by separating them with a line of `---`.
