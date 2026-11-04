// Replays a timestamped transcript through the real detection code on a simulated clock, and reports
// how it did. Used by the tests and by scripts/replay-lyrics.mjs.
//
// Fixture format:
//   { name, setlist: [songId], songs?: [...], events: [{ t: ms, final: "text" }],
//     truth: [{ from: ms, to: ms, song: songId|null, section?, line? }] }
import { LyricsEngine } from './engine.js';
import { SAMPLE_SONGS } from './sampleSongs.js';
import { arrangementOf } from './songs.js';

export function runReplay(fixture, { thresholds, library: libraryOption } = {}) {
  const library = libraryOption ?? fixture.songs ?? SAMPLE_SONGS;
  const byId = new Map(library.map((song) => [song.id, song]));
  const setlist = (fixture.setlist ?? []).map((id) => byId.get(id)).filter(Boolean);

  let time = 0;
  const locks = [];
  const clears = [];
  const positions = [];
  const engine = new LyricsEngine({
    thresholds,
    now: () => time,
    onEvent(event) {
      if (event.type === 'proposal') {
        engine.lock(event.songId, { index: event.startIndex });
        locks.push({ t: time, song: event.songId });
      } else if (event.type === 'songChange') {
        engine.lock(event.songId, { index: event.startIndex });
        locks.push({ t: time, song: event.songId });
      } else if (event.type === 'quiet' || event.type === 'ended') {
        clears.push({ t: time, type: event.type });
      }
    },
  });
  engine.setSongs({ setlist, library });

  const truthAt = (t) => (fixture.truth ?? []).find((span) => t >= span.from && t <= span.to) ?? null;
  const end = Math.max(0, ...fixture.events.map((e) => e.t)) + (fixture.tailMs ?? 90_000);
  const events = [...fixture.events].sort((a, b) => a.t - b.t);
  let next = 0;
  const lineSamples = [];
  let staleMs = 0;

  for (time = 0; time <= end; time += 500) {
    while (next < events.length && events[next].t <= time) {
      engine.addFinal({ text: events[next].final, words: events[next].words });
      const truth = truthAt(events[next].t);
      const position = engine.position?.();
      if (truth?.song && truth.line != null && engine.locked?.songId === truth.song && position) {
        const lines = arrangementOf(byId.get(truth.song));
        const tracked = lines[position.index];
        const expected = lines.filter((line) => line.sectionId === truth.section && line.lineIndex === truth.line);
        const offBy = Math.min(...expected.map((line) => Math.abs(line.index - position.index)));
        const sameText = expected.some((line) => line.text === tracked?.text);
        lineSamples.push({ t: events[next].t, exact: sameText, close: sameText || offBy <= 1 });
      }
      positions.push({ t: events[next].t, index: position?.index ?? null });
      next++;
    }
    engine.tick();
    if (engine.showing?.() && !truthAt(time)?.song) staleMs += 500;
  }

  // Per song performance in the transcript, in order of first appearance.
  const songSpans = [];
  for (const span of fixture.truth ?? []) {
    if (!span.song) continue;
    const last = songSpans.at(-1);
    if (last?.song === span.song && span.from - last.to < 15_000) last.to = span.to;
    else songSpans.push({ song: span.song, from: span.from, to: span.to });
  }
  const songs = songSpans.map((span) => {
    const lock = locks.find((l) => l.song === span.song && l.t >= span.from && l.t <= span.to + 5000);
    return { song: span.song, from: span.from, detectedAfterMs: lock ? lock.t - span.from : null };
  });
  const wrong = locks.filter((lock) => {
    const truth = truthAt(lock.t);
    const recent = truth ?? truthAt(lock.t - 5000);
    return recent?.song !== lock.song;
  });

  const detected = songs.filter((s) => s.detectedAfterMs != null);
  return {
    name: fixture.name,
    songs,
    locks,
    clears,
    wrongDetections: wrong.length,
    wrong,
    missed: songs.length - detected.length,
    meanDetectMs: detected.length ? detected.reduce((sum, s) => sum + s.detectedAfterMs, 0) / detected.length : null,
    lineSamples: lineSamples.length,
    lineExact: lineSamples.length ? lineSamples.filter((s) => s.exact).length / lineSamples.length : null,
    lineClose: lineSamples.length ? lineSamples.filter((s) => s.close).length / lineSamples.length : null,
    staleMs,
  };
}
