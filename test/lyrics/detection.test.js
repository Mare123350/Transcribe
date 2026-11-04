import test from 'node:test';
import assert from 'node:assert/strict';
import { resolveThresholds } from '../../shared/lyrics/config.js';
import { SAMPLE_SONGS } from '../../shared/lyrics/sampleSongs.js';
import { SongDetector } from '../../shared/lyrics/songDetector.js';
import { SongIndex } from '../../shared/lyrics/songIndex.js';
import { normalizeWords } from '../../shared/lyrics/text.js';
import { classifyWorshipReference, routeFor } from '../../shared/lyrics/serviceMode.js';

const SHARED = 'We will gather by the open door';

function setup({ setlist = [], library = SAMPLE_SONGS, thresholds } = {}) {
  let time = 0;
  const detector = new SongDetector({ thresholds: resolveThresholds(thresholds), now: () => time });
  detector.setSongs({ setlist, library });
  return {
    detector,
    sing(text, ms = 4000) {
      time += ms;
      return detector.update(normalizeWords(text));
    },
  };
}

test('index: a line in several songs knows it is shared', () => {
  const index = new SongIndex(SAMPLE_SONGS);
  const key = normalizeWords(SHARED).join(' ');
  const copies = index.lines.filter((line) => line.key === key);
  assert.equal(copies.length, 3);
  assert.ok(copies.every((line) => Math.abs(line.uniqueness - 1 / 3) < 0.01));
  const unique = index.lines.find((line) => line.key === normalizeWords('A copper bell rings out above the river').join(' '));
  assert.equal(unique.uniqueness, 1);
});

test('index: nearly identical lines count as shared', () => {
  const song = (id, line) => ({ id, title: id, order: ['v'], sections: [{ id: 'v', label: 'V', lines: [line] }] });
  const index = new SongIndex([song('a', 'Lift your voice across the silver valley'), song('b', 'Lift your voices across the silver valley')]);
  assert.ok(index.lines.every((line) => line.uniqueness === 0.5));
});

test('scoring: several distinct lines from one song build to a confident match', () => {
  const { sing } = setup();
  const first = sing('A copper bell rings out above the river');
  assert.ok(first.candidates[0].confidence < 0.75);
  assert.equal(first.candidates[0].eligible, false, 'one line is never enough');
  sing('Shaking dust from every beam');
  const third = sing('Children running through the wheat and clover');
  assert.equal(third.candidates[0].songId, 'sample-lantern');
  assert.equal(third.candidates[0].eligible, true);
  assert.ok(third.candidates[0].confidence >= 0.75);
});

test('scoring: misheard words still identify the song', () => {
  const { sing } = setup();
  sing('a copper belt rings out above the rivers');
  sing('shaking dusk from every bean');
  const last = sing('children running through the weed and clover');
  assert.equal(last.candidates[0].songId, 'sample-lantern');
  assert.equal(last.candidates[0].eligible, true);
});

test('scoring: one line sung over and over adds nothing', () => {
  const { sing } = setup();
  let result;
  for (let i = 0; i < 8; i++) result = sing('A copper bell rings out above the river');
  assert.equal(result.candidates[0].eligible, false, 'vamping needs other lines for support');
  assert.ok(result.candidates[0].raw < 0.75);
});

test('shared lines: a line in three songs never triggers a match by itself', () => {
  const { sing } = setup();
  let result;
  for (let i = 0; i < 8; i++) {
    result = sing(SHARED);
    assert.ok(result.candidates.every((c) => !c.eligible), 'never proposed');
  }
  assert.ok(result.candidates.every((c) => c.confidence < 0.2), 'confidence stays low when songs tie');
});

test('shared lines: a shared line plus distinctive lines finds the right song', () => {
  const { sing } = setup();
  sing(SHARED);
  sing('Kettle singing on the stove');
  const last = sing('Tell the story one time more');
  assert.equal(last.candidates[0].songId, 'sample-meadow');
  assert.equal(last.candidates[0].eligible, true);
});

test('shared lines: when songs tie, the top candidates are all offered', () => {
  const twoSongs = SAMPLE_SONGS.filter((song) => ['sample-lantern', 'sample-orchard', 'sample-meadow'].includes(song.id));
  const { sing } = setup({ library: twoSongs, thresholds: { suggestThreshold: 0.1 } });
  const { candidates } = sing(SHARED);
  assert.equal(candidates.length, 3);
});

test('setlist: searched first, so its song wins a shared line', () => {
  const setlist = SAMPLE_SONGS.filter((song) => song.id === 'sample-orchard');
  const { sing } = setup({ setlist });
  const { candidates } = sing(SHARED);
  assert.equal(candidates[0].songId, 'sample-orchard');
  assert.equal(candidates[0].scope, 'setlist');
  assert.equal(candidates.length, 1);
});

test('setlist: the library is only used when the setlist has no match', () => {
  const setlist = SAMPLE_SONGS.filter((song) => song.id === 'sample-orchard');
  const { sing } = setup({ setlist });
  const { candidates } = sing('A copper bell rings out above the river');
  assert.equal(candidates[0].songId, 'sample-lantern');
  assert.equal(candidates[0].scope, 'library');
});

test('ordinary speech matches nothing', () => {
  const { sing } = setup();
  for (const text of ['Good morning church it is wonderful to see all of you today', 'Please turn to the book of Romans and let us read together', 'We thank the choir for that beautiful song this morning']) {
    assert.deepEqual(sing(text).candidates, [], text);
  }
});

test('rejected songs stay out until allowed again', () => {
  const { detector, sing } = setup();
  sing('A copper bell rings out above the river');
  detector.reject('sample-lantern');
  assert.deepEqual(sing('Shaking dust from every beam').candidates, []);
  detector.allow('sample-lantern');
  assert.equal(sing('Children running through the wheat and clover').candidates[0].songId, 'sample-lantern');
});

test('evidence expires, so an old song does not linger', () => {
  const { sing } = setup();
  sing('A copper bell rings out above the river');
  sing('Shaking dust from every beam');
  assert.ok(sing('Good morning everyone', 60_000).candidates.length === 0);
});

test('thresholds are configurable', () => {
  const strict = setup({ thresholds: { autoThreshold: 0.99 } });
  strict.sing('A copper bell rings out above the river');
  strict.sing('Shaking dust from every beam');
  assert.equal(strict.sing('Children running through the wheat and clover').candidates[0].eligible, false);

  const eager = setup({ thresholds: { autoThreshold: 0.5, minDistinctLines: 1, minConsecutiveWindows: 1 } });
  assert.equal(eager.sing('A copper bell rings out above the river').candidates[0].eligible, true);
  assert.equal(resolveThresholds({ autoThreshold: 'nonsense' }).autoThreshold, 0.75);
  assert.equal(resolveThresholds({ unknown: 1 }).unknown, undefined);
});

test('modes: sermon mode never runs lyric detection', () => {
  assert.deepEqual(routeFor('sermon'), { verses: true, lyrics: false, activity: 'sermon' });
  assert.equal(routeFor('worship').lyrics, true);
  assert.equal(routeFor('auto', 'sermon').activity, 'sermon');
  assert.equal(routeFor('auto', 'worship').activity, 'worship');
});

test('worship references: lyric, noise, or a quick mention', () => {
  const never = { isLyric: () => false };
  const confirmed = { status: 'confirmed', refs: [{}], phrase: 'Psalm twenty three' };
  assert.equal(classifyWorshipReference(confirmed, never), 'aside');
  assert.equal(classifyWorshipReference(confirmed, { isLyric: () => true }), 'lyric');
  assert.equal(classifyWorshipReference({ status: 'invalid', refs: [{}], phrase: 'x' }, never), 'noise');
  assert.equal(classifyWorshipReference({ status: 'suggestion', refs: [{}], phrase: 'Mark two' }, never), 'noise', 'a name and a number, sung, is likely not a reference');
  assert.equal(classifyWorshipReference({ status: 'suggestion', refs: [{}, {}], phrase: 'Corinthians thirteen' }, never), 'aside');
});

test('worship references: a lyric that quotes a reference is recognized', () => {
  const song = { id: 'x', title: 'x', order: ['v'], sections: [{ id: 'v', label: 'V', lines: ['We shout it out John 3:16 today'] }] };
  const { detector } = setup({ library: [song] });
  assert.equal(detector.containsPhrase(normalizeWords('John three sixteen')), true);
  assert.equal(detector.containsPhrase(normalizeWords('Psalm twenty three')), false);
});
