# Transcribe

Listens to a preacher, transcribes the sermon live, picks out spoken Bible references, looks up the passage, and shows it on a separate screen for the congregation.

```
Audio input → speech-to-text → normalization → regex detection → validation → Bible lookup → screen
```

## Quick start

You need [Node.js](https://nodejs.org) 22.9 or newer, and Chrome or Edge for the operator screen.

```bash
npm install
npm start
```

Then open **http://localhost:3000** on the operator computer.

**To try it with no microphone or accounts:** press **Demo mode**, then **Open display**, then **Play sample**. Demo mode plays sample transcripts through the real detection pipeline and shows real scripture. It's labelled on both the operator screen and the congregation screen.

With no configuration at all you get:

- KJV and WEB, bundled, so lookups work without internet
- Browser speech recognition in Chrome or Edge, which uses the system's default microphone
- Demo mode

## Setting up for a service

1. **Choose your transcription** (see the next section).
2. Press **Open display**, drag that window to the projector, and press **F** for fullscreen.
3. Pick **Review** or **Automatic** mode, and a default Bible version.
4. Choose your audio input and press **Start**. The browser will ask for microphone access.

Test with your real sound system before a service. Accuracy depends heavily on how clean the audio is, so a feed from the mixing desk will do much better than a laptop microphone across the room.

## Configuration

Copy `.env.example` to `.env`, fill in what you need, and restart. Keys stay on the server and are never sent to the browser.

### Transcription

| Option | Setup | Choose your input? | Where audio goes |
| --- | --- | --- | --- |
| **Deepgram** (recommended) | Set `DEEPGRAM_API_KEY` | Yes, any input | To Deepgram, through this server. Billed per minute of audio. |
| **Browser speech recognition** | None; Chrome or Edge only | No, always the system default | Chrome sends it to Google |

Get a Deepgram key at [console.deepgram.com](https://console.deepgram.com). The app sets `mip_opt_out=true` so Deepgram doesn't keep audio for model improvement; check their current pricing, since this can affect the rate. Set `TRANSCRIPTION_LANGUAGE` to match your congregation's English, such as `en-GB` or `en-NG`, if the provider supports it.

### Bible translations

| Version | Source | What you need |
| --- | --- | --- |
| KJV, WEB | Bundled | Nothing |
| NKJV, NIV, NLT, NASB, NRSV | [API.Bible](https://api.bible) | `API_BIBLE_KEY` and `API_BIBLE_ID_<VERSION>` |
| ESV | [ESV API](https://api.esv.org) | `ESV_API_KEY` |

Licensed versions show as unavailable, with the reason, until they're configured. The app never swaps in a different version or generates text. If a lookup fails, you get an error and the screen stays as it was.

**Licensing is your responsibility.** A key doesn't automatically grant rights to every version or to public display:

- **API.Bible:** which Bibles you can read depends on your account and licences, so some of these versions may not be available to you. List yours with `curl -H "api-key: $API_BIBLE_KEY" https://rest.api.bible/v1/bibles`, and read their fair-use (view tracking) requirements. This app doesn't report views, so check whether your plan requires that.
- **ESV:** read [Crossway's conditions](https://api.esv.org/#conditions). The app caps its cache at their 500-verse limit and shows "ESV" and a copyright line. Check their exact required wording and whether their terms fit your use.
- **KJV:** public domain in most of the world, but under Crown copyright in the UK.

To add a translation, add one line to [server/bible/translations.js](server/bible/translations.js). If it's on API.Bible, that's all the code it needs.

### Projector on a different computer

By default the server only accepts connections from its own computer. To run the display elsewhere on your network:

```
HOST=0.0.0.0
ALLOWED_HOSTS=192.168.1.50   # the operator computer's address
```

Then open `http://192.168.1.50:3000/display` on the projector computer. Other computers can only view the display page: operator controls, lookups, and transcription stay limited to the operator computer. Traffic isn't encrypted and the display page has no login, so anyone on that network can view it. Only do this on a network you trust.

## Using it

**Review mode** queues everything for your approval. The newest reference is loaded into the preview, so one press of **Send to Screen** puts it up.

**Automatic mode** sends validated, unambiguous references straight to the screen. Anything uncertain still waits as a card marked *Needs confirmation*.

A reference needs confirmation when:

| Situation | Example | What happens |
| --- | --- | --- |
| A numbered book without its number | "Corinthians thirteen" | Offers 1 and 2 Corinthians |
| A possible mishearing | "Philippines four thirteen" | Offers Philippians 4:13 |
| A name and one number | "Mark two" | Could be ordinary speech |
| A verse with no book | "verse seventeen" | Assumes the previous reference's chapter |
| A chapter that doesn't exist | "John twenty eight" | Offers John 20:8 |

Other useful controls:

- **Correct** on any card fixes a misheard reference. Chips switch between possible readings, like Psalm 23 and Psalm 20:3.
- **Find a passage** takes references in almost any form: `John 3:16`, `1 cor 13:4-7`, `first corinthians thirteen`.
- **‹ Verse / Verse ›** moves through the text in the preview. **‹ Page / Page ›** (or the arrow keys) turns the page, which is immediate if that passage is on screen.
- The passage on screen stays until you send another or press **Clear screen**.

## Worship lyrics

Transcribe can also follow a live choir and show the current lyrics. It doesn't use audio fingerprinting, which matches studio recordings. It matches what it hears against your own song library.

**To try it:** press **Demo mode**, then **Worship**, choose the **Worship set** sample, and press **Play sample**. The demo uses clearly fake sample songs.

### Setting up
1. **Songs** opens the library. Paste lyrics with labels such as `[Verse 1]` and `[Chorus]`, or import OpenLyrics files. A bare `[Chorus]` later in the text means "repeat it here". Each line of text is one line on screen.
2. On the **Setlists** tab, build the service and press **Use for this service**. Setlist songs are searched first, and the full library only if nothing in the setlist matches.
3. Under **Display and credit settings**, add your CCLI licence number and choose one or two lines on screen.

No lyrics ship with the app, apart from the fake samples. Your library lives in `library/lyrics.json` on this computer, with earlier versions in `library/backups/`, and is gitignored. **Export all** downloads a copy. Only add lyrics your church is licensed to use.

For worship, use **Deepgram**. Browser speech recognition handles singing poorly and can't use the choir's input. A feed from the mixing desk with vocals up will work far better than a room microphone.

### What it's listening for

| Mode | Lyrics | Bible references |
| --- | --- | --- |
| **Sermon** | Off | Normal |
| **Worship** | Followed | Only offered as quick mentions |
| **Auto-detect** | Used as evidence, followed once worship is established | Normal during a sermon, quick mentions during worship |

**Review** and **Automatic** still decide who approves what goes up. In Review, a confident song match waits for **Confirm**; after that, lines follow automatically. In Automatic, a confident match goes straight up. In both, anything less certain is offered as up to three suggestions and nothing changes on screen.

### Bible references during worship
Each reference heard during worship is sorted into one of three cases:

- **Part of a song:** ignored.
- **A quick mention**, like "as Psalm 23 reminds us": a card marked *Mentioned during worship*. It never goes up by itself, even in Automatic. **Show briefly** puts it up, and **Back to lyrics** returns to the song at the current line.
- **Actual preaching:** more than a minute of speech at talking pace with almost no lyrics. Worship mode asks whether to switch to Sermon. Auto-detect switches by itself.

### Staying in control
- Moving a line, jumping to a section, or blanking the screen pauses auto-follow. Automation won't touch the screen again until you press **Resume auto-follow**. The tracker keeps listening in the background, so resuming catches up with the singing.
- A song you pick yourself can't be replaced or cleared by automation. You'll only see suggestions and notices.
- Everything works by hand with transcription off or failed.
- With no singing heard for 30 seconds, lyrics come off the screen and return if the song resumes. After 75 seconds the song is treated as over.

### Testing with transcripts
A replay harness runs timestamped transcripts through the real detection code with no microphone:

```bash
npm run replay                                        # all samples in test/fixtures/replay/
npm run replay -- my-service.json --songs library/lyrics.json
npm run replay -- --set autoThreshold=0.65 --auto     # try a threshold; --auto simulates Auto-detect
```

It reports time to detect each song, wrong detections, and line-tracking accuracy. A transcript file looks like this, and `truth` is what was really being sung:

```json
{
  "name": "sunday-choir",
  "setlist": ["song-id"],
  "events": [{ "t": 12000, "final": "text the engine produced" }],
  "truth": [{ "from": 10000, "to": 15000, "song": "song-id", "section": "v1", "line": 0 }]
}
```

The sample transcripts are synthetic, generated by `scripts/make-replay-fixtures.mjs`.

### Tuning
Every number is in [shared/lyrics/config.js](shared/lyrics/config.js), with a comment. **The defaults were tuned on synthetic transcripts, not a real choir, so expect to adjust them.** Try a change with `npm run replay -- --set name=value`. To keep it, stop the app, add it under `settings` → `thresholds` in `library/lyrics.json` (for example `"thresholds": { "autoThreshold": 0.65 }`), and start the app again.

| What you're seeing | Try changing |
| --- | --- |
| Songs take too long to be detected | Lower `autoThreshold` or `scoreScale`; lower `minLineCoverage` if the transcript is poor |
| The wrong song gets proposed | Raise `autoThreshold` or `minDistinctLines` |
| Too many weak suggestions | Raise `suggestThreshold` |
| The line lags behind the choir | Lower `advanceCoverage` |
| The line jumps around | Raise `jumpCoverage`, `strongJumpCoverage` or `strongJumpWords` |
| Lost after a missed line | Raise `skipAheadLines`, or lower `skipCoverage` |
| Lyrics vanish during instrumental breaks | Raise `staleClearMs` and `songEndMs` |
| Lyrics stay up too long after a song | Lower `staleClearMs` |
| Auto-detect switches too slowly or eagerly | Change `worshipSustainMs` and `sermonSustainMs` |
| Singing gets flagged as preaching | Raise `sermonMinWordsPerMinute` |

## Privacy

- Audio is never saved by this app.
- Transcripts stay in memory and are lost when the page closes.
- **Privacy → Save transcripts** writes finished lines of text to `saved-transcripts/YYYY-MM-DD.txt`. It's off by default, and resets to off every time the page loads.
- A red **LISTENING** indicator and the browser tab title show when audio is being captured. **Pause** and **Stop** cut the audio immediately.

## How detection works

Each step is its own module in [shared/](shared/), and the browser and the tests run the same code.

| Step | File | What it does |
| --- | --- | --- |
| Book names | [books.js](shared/books.js) | The 66 books, with aliases and common mishearings |
| Normalization | [normalize.js](shared/normalize.js) | `First Corinthians thirteen, verses four to seven` → `1 corinthians 13 verses 4 to 7` |
| Regex parsing | [parser.js](shared/parser.js) | Finds candidates, works out possible readings, decides what's ambiguous |
| Validation | [validate.js](shared/validate.js) | Checks against the selected translation's own chapters and verses |
| Rolling buffer | [detector.js](shared/detector.js) | Handles interim and final results, split references, and duplicates |
| Pagination | [pagination.js](shared/pagination.js) | Splits long passages into screens |

How it avoids false or repeated triggers:

- **Only final text triggers a detection.** Interim text only shows as "Hearing: …".
- **A reference at the end of the transcript is held** for 1.2 seconds or until more words arrive, because "John three" may be about to become "John three sixteen". This adds a short delay in Automatic mode.
- **After 8 seconds of silence** a book name and a later number won't join together.
- **Each stretch of transcript is handled once**, and the same reference said again within 45 seconds is counted on its card rather than shown again.

This MVP detects **explicit references only**. It won't recognize a verse from a quotation or paraphrase, and regexes can't do that reliably.

The verse tables for API-based versions come from the KJV, because verse counts differ slightly between translations. For those versions, a verse past the table's end is passed to the provider, which gives the final answer.

## Tests

```bash
npm test                 # unit and integration tests
npm run test:browser     # end-to-end checks in real Chrome, with a fake mic and stand-in Deepgram
npm run replay           # lyric detection against sample transcripts
```

The tests cover spoken-number normalization, numbered books, verse ranges, segmented transcripts, duplicate detection, invalid references, ordinary speech that shouldn't trigger, Bible providers, the Deepgram relay, the display hub, and pagination. Network services are replaced with stand-ins, and timing tests use a simulated clock.

## Bundled scripture data

`npm run data:build` regenerates [data/](data/) from these sources. The script changes only whitespace, and it also regenerates the verse table in `shared/versification.js`.

- **KJV:** [aruljohn/Bible-kjv](https://github.com/aruljohn/Bible-kjv) (MIT-licensed repository of the public-domain text). It uses modernized spelling in places, such as "first born" and "thoroughly".
- **WEB:** [TehShrike/world-english-bible](https://github.com/TehShrike/world-english-bible) (public-domain text). A few verses the WEB leaves out, like Acts 8:37, are reported as not in this translation.

## Project layout

```
server/         Express server, Bible providers, Deepgram relay, display hub
shared/         Detection pipelines, used by the browser and the tests
shared/lyrics/  Song model, matching, position tracking, replay
public/         Operator dashboard and congregation display
data/           Bundled public-domain Bibles
library/        Your songs and setlists (created on first save, gitignored)
scripts/        Rebuilds data/, generates and replays transcripts
test/           Automated tests
```

## Troubleshooting

| Problem | Try |
| --- | --- |
| Inputs show as "Audio input 1" | Press **Allow microphone to list inputs** |
| Microphone blocked | Click the icon in the address bar, allow the microphone, and press Start |
| Can't choose an input | Browser speech recognition always uses the system default. Change it in system settings, or set up Deepgram |
| "No screens" | Press **Open display**. A pop-up blocker may have stopped it |
| A version is greyed out | It isn't configured. Hover over it to see what's needed |
| Port already in use | Set `PORT=3001` in `.env` |
