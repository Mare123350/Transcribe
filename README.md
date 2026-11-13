# Transcribe

A native macOS app that transcribes live church services entirely on-device. It recognizes songs from your library and replaces the sung transcription with clean lyrics, spots Bible references and quoted verses and works out which translation is being read, adds section headers (Welcome, Worship, Sermon…), and exports to Markdown, PDF, Word, or plain text.

No cloud services, no API keys, and no audio leaves the Mac.

## Requirements

- macOS 26 or later
- Xcode 26 or later to build
- Apple Intelligence turned on for smart headers, sermon titles, and summaries (optional: without it, headers use keyword matching and summaries are unavailable)

## Build and run

```bash
open Transcribe.xcodeproj      # then press ⌘R
```

Or from Terminal:

```bash
xcodebuild -project Transcribe.xcodeproj -scheme Transcribe build
open ~/Library/Developer/Xcode/DerivedData/Transcribe-*/Build/Products/Debug/Transcribe.app
```

Run the unit tests:

```bash
cd Packages/TranscribeKit && swift test
```

The first recording downloads Apple's on-device speech model for your language (once, shared with other apps).

## Using it

| Action | Shortcut |
| --- | --- |
| Record / pause | ⌘R |
| Stop | ⌘. |
| Insert header | ⌘H (Hide Transcribe moves to ⌃⌘H) |
| Insert verse | ⌘B |
| Export | ⌘E |
| Presentation mode | ⇧⌘P, then ⌃⌘F for full screen |
| Song library | ⇧⌘L |
| Bigger / smaller text | ⌘+ / ⌘− |

- **Audio input:** pick the built-in mic, a USB mic, or an audio interface carrying the sound-desk feed from the toolbar. A desk feed gives far better results than a laptop mic.
- **Autosave:** the session is saved every 30 seconds. If the app quits unexpectedly, the session reopens marked "(recovered)".
- **Songs:** when a library song is recognized, a "Detected: Amazing Grace (87%)" chip appears. Confirm, change, or dismiss it. The sung transcription stays available, folded under the song.
- **Scripture:** references like "first Corinthians thirteen verse four" become callouts showing the verse. Transcribe listens to the reading and picks the closest translation ("John 3:16 — KJV, 92%"). If the speaker names a version ("in the NIV…"), that wins. Verses quoted without a reference are recognized from their wording.
- **Headers:** edit inline; right-click to change the type, merge with the previous section, or delete.

## Translations and licensing

KJV, WEB, BSB, ASV, and YLT are public domain and bundled. Copyrighted versions (NIV, ESV, NKJV, NLT, and others) are **not** included. If your church is licensed to use one, import it in Settings › Scripture using the format in [docs/TRANSLATION_FORMAT.md](docs/TRANSLATION_FORMAT.md).

The bundled song library holds public-domain hymns only. Import modern worship songs under your CCLI (or similar) licence; see [docs/SONG_FORMAT.md](docs/SONG_FORMAT.md).

## Project layout

```
Transcribe/                 App target (SwiftUI, SwiftData, MVVM)
  App/                      App entry point and menu commands
  Models/                   SwiftData models: Session, TranscriptItem, StoredSong
  Services/                 View models: recording, scripture, songs, sections, export
  Views/                    Three-pane UI, presentation mode, song library, settings
  Resources/                Bundled Bibles (SQLite) and songs.json
Packages/TranscribeKit/     Unit-testable modules
  AudioCapture              AVAudioEngine capture and input-device selection (actor)
  Transcriber               SpeechAnalyzer/SpeechTranscriber, with an on-device SFSpeechRecognizer fallback (actors)
  SongMatcher               N-gram song matching, song start/end tracking, JSON/TXT import
  ScriptureDetector         Spoken reference parser, version scorer, quote index, SQLite translations
  SectionClassifier         Foundation Models (@Generable) section headers and sermon summaries, keyword fallback
  Exporter                  Markdown, plain text, PDF (Core Text), and DOCX
  TranscribeSmoke           Developer tool: runs an audio file through the pipeline
Tools/build_bibles.py       Rebuilds the bundled Bible databases
```

### Developer tools

```bash
cd Packages/TranscribeKit
say -o /tmp/clip.aiff "Turn with me to John chapter three verse sixteen. For God so loved the world…"
BIBLES=../../Transcribe/Resources/Bibles SONGS=../../Transcribe/Resources/songs.json \
  swift run -c release TranscribeSmoke /tmp/clip.aiff
SECTIONS=1 swift run -c release TranscribeSmoke   # checks the Foundation Models classifier
```

Debug builds accept `-PipelineSelfTest`: the app runs a scripted service through the real detection pipeline in memory, writes the Markdown export to its temporary folder, and quits.
