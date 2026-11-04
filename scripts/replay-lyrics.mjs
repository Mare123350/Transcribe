// Runs transcript files through lyric detection with no microphone.
//   node scripts/replay-lyrics.mjs [files or folders] [--set name=value] [--songs library.json] [--auto] [--json]
// With no files, runs everything in test/fixtures/replay/.
import { readdirSync, readFileSync, statSync } from 'node:fs';
import { join } from 'node:path';
import { DEFAULT_THRESHOLDS } from '../shared/lyrics/config.js';
import { runReplay } from '../shared/lyrics/replay.js';

const args = process.argv.slice(2);
const thresholds = {};
const paths = [];
let library;
let asJson = false;
let autoDetect = false;
for (let i = 0; i < args.length; i++) {
  if (args[i] === '--set') {
    const [name, value] = args[++i].split('=');
    if (!(name in DEFAULT_THRESHOLDS)) {
      console.error(`Unknown threshold "${name}". Known: ${Object.keys(DEFAULT_THRESHOLDS).join(', ')}`);
      process.exit(2);
    }
    thresholds[name] = Number(value);
  } else if (args[i] === '--songs') {
    const parsed = JSON.parse(readFileSync(args[++i], 'utf8'));
    library = parsed.songs ?? parsed;
  } else if (args[i] === '--auto') {
    autoDetect = true;
  } else if (args[i] === '--json') {
    asJson = true;
  } else {
    paths.push(args[i]);
  }
}

const expand = (path) => (statSync(path).isDirectory()
  ? readdirSync(path).filter((name) => name.endsWith('.json')).sort().map((name) => join(path, name))
  : [path]);
const files = (paths.length ? paths : [new URL('../test/fixtures/replay', import.meta.url).pathname]).flatMap(expand);
const results = files.map((file) => runReplay(JSON.parse(readFileSync(file, 'utf8')), { thresholds, library, autoDetect }));

if (asJson) {
  console.log(JSON.stringify(results, null, 2));
} else {
  const seconds = (ms) => (ms == null ? '–' : `${(ms / 1000).toFixed(1)}s`);
  const percent = (share) => (share == null ? '–' : `${Math.round(share * 100)}%`);
  const rows = results.map((r) => ({
    Transcript: r.name,
    Songs: r.songs.length,
    Found: r.songs.length - r.missed,
    'Mean time to detect': seconds(r.meanDetectMs),
    Wrong: r.wrongDetections,
    'Line exact': percent(r.lineExact),
    'Within 1 line': percent(r.lineClose),
    'Lyrics up with no song': seconds(r.staleMs),
    'Mode switches': r.switches.map((s) => `${s.activity} ${seconds(s.t)}`).join(', ') || '–',
  }));
  console.table(rows);
  for (const r of results) {
    for (const w of r.wrong) console.log(`  wrong: ${r.name} locked ${w.song} at ${seconds(w.t)}`);
    for (const s of r.songs) if (s.detectedAfterMs == null) console.log(`  missed: ${r.name} never found ${s.song} (starts ${seconds(s.from)})`);
  }
}
