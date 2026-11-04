import test from 'node:test';
import assert from 'node:assert/strict';
import { resolveThresholds } from '../../shared/lyrics/config.js';
import { LyricsEngine } from '../../shared/lyrics/engine.js';
import { PositionTracker } from '../../shared/lyrics/positionTracker.js';
import { SAMPLE_SONGS } from '../../shared/lyrics/sampleSongs.js';
import { arrangementOf } from '../../shared/lyrics/songs.js';
import { normalizeWords } from '../../shared/lyrics/text.js';

const thresholds = resolveThresholds();
const songById = (id) => SAMPLE_SONGS.find((s) => s.id === id);

function tracker(id, startIndex = 0) {
  const song = songById(id);
  const t = new PositionTracker(song, { thresholds, startIndex });
  let at = 0;
  return {
    t,
    lines: arrangementOf(song),
    sing(text) {
      at += 5000;
      t.update(normalizeWords(text), at);
      return t.lines[t.index];
    },
  };
}

test('moves forward line by line', () => {
  const { sing } = tracker('sample-lantern');
  assert.equal(sing('Carried by the evening tide').text, 'Carried by the evening tide');
  assert.equal(sing('Every window on the harbor glowing').lineIndex, 2);
  assert.equal(sing('Calling all the sailors home tonight').lineIndex, 3);
  const chorus = sing('Sing out across the morning bay');
  assert.equal(chorus.sectionId, 'c');
  assert.equal(chorus.orderIndex, 1);
});

test('handles several lines arriving in one transcript update', () => {
  const { sing } = tracker('sample-lantern');
  assert.equal(sing('Carried by the evening tide every window on the harbor glowing').lineIndex, 2);
});

test('tolerates misheard words', () => {
  const { sing } = tracker('sample-lantern');
  assert.equal(sing('carried by the even tied').lineIndex, 1);
  assert.equal(sing('every widow on the harper glowing').lineIndex, 2);
});

test('a missing line does not lose the place', () => {
  const { sing } = tracker('sample-lantern');
  sing('Carried by the evening tide');
  // "Every window..." was never transcribed, so the tracker skips straight past it.
  assert.equal(sing('Calling all the sailors home tonight').lineIndex, 3);
  assert.equal(sing('Sing out across the morning bay').sectionId, 'c');
});

test('vamping on one line stays put and counts the repeats', () => {
  const { sing, t } = tracker('sample-tide', arrangementOf(songById('sample-tide')).length - 1);
  const before = t.index;
  for (let i = 0; i < 6; i++) sing('Keep on rowing keep on rowing');
  assert.equal(t.index, before);
  assert.ok(t.repeats >= 5);
});

test('repeated chorus: singing it again loops in the same place, not the next chorus', () => {
  const { sing, lines } = tracker('sample-lantern');
  for (const line of ['Carried by the evening tide', 'Every window on the harbor glowing', 'Calling all the sailors home tonight']) sing(line);
  const chorusLines = ['Sing out across the morning bay', 'Sing until the fog rolls away', 'We will gather by the open door', 'Lifting up our voices on the shore'];
  for (const line of chorusLines) sing(line);
  for (const line of chorusLines) {
    const at = sing(line);
    assert.equal(at.orderIndex, lines.find((l) => l.sectionId === 'c').orderIndex, `still the first chorus at: ${line}`);
  }
  // Now verse 2 starts, and the following chorus is the right one.
  assert.equal(sing('A copper bell rings out above the river').sectionId, 'v2');
  sing('Shaking dust from every beam');
  sing('Children running through the wheat and clover');
  sing('Following the current of the stream');
  assert.equal(sing('Sing out across the morning bay').orderIndex, 3);
});

test('repeated text: a line in two sections does not jump without support', () => {
  // In [Sample] Evening Tide, "Hold the rope" is in both the chorus and verse 2.
  const { sing, t, lines } = tracker('sample-tide', 0);
  const before = t.index;
  sing('Hold the rope and pull together');
  assert.equal(t.index, before, 'one occurrence of shared text is not enough to move');
  assert.equal(lines[t.index].sectionId, 'v1');
});

test('repeated text: the next line provides the support to resolve it', () => {
  const { sing, lines, t } = tracker('sample-tide', 0);
  sing('Hold the rope and pull together');
  sing('Lamplight trembling on the cabin ceiling');
  assert.equal(lines[t.index].sectionId, 'v2', 'verse 2, because that line follows there');
});

test('repeated text: a line repeated inside a section moves one line at a time', () => {
  const lines = arrangementOf(songById('sample-tide'));
  const firstChorus = lines.findIndex((l) => l.sectionId === 'c');
  const { sing, t } = tracker('sample-tide', firstChorus);
  sing('Hold the rope and pull together');
  assert.equal(t.index, firstChorus + 1, 'the identical next line');
  assert.equal(sing('Steady through the wind and weather').lineIndex, 2);
});

test('skipped section: a clear distinctive line jumps straight there', () => {
  const { sing } = tracker('sample-lantern');
  const at = sing('Higher than the mountain pines');
  assert.equal(at.sectionId, 'b');
});

test('out of order: going back to an earlier verse works', () => {
  const lines = arrangementOf(songById('sample-lantern'));
  const { sing } = tracker('sample-lantern', lines.findIndex((l) => l.sectionId === 'b'));
  assert.equal(sing('A lantern drifts across the silver water').sectionId, 'v1');
  assert.equal(sing('Carried by the evening tide').lineIndex, 1);
});

test('unrelated words change nothing', () => {
  const { sing, t } = tracker('sample-lantern', 2);
  sing('Please turn with me and let us read this together');
  sing('Good morning everybody how are you today');
  assert.equal(t.index, 2);
});

test('a short weak match does not jump', () => {
  const { sing, t } = tracker('sample-lantern', 0);
  sing('the morning');
  assert.equal(t.index, 0);
});

function engineHarness() {
  let time = 0;
  const events = [];
  const engine = new LyricsEngine({ now: () => time, onEvent: (event) => events.push(event) });
  engine.setSongs({ library: SAMPLE_SONGS });
  return {
    engine,
    events,
    types: () => events.map((e) => e.type),
    sing(text, ms = 5000) {
      time += ms;
      engine.addFinal({ text });
    },
    wait(ms) {
      for (let i = 0; i < ms; i += 1000) {
        time += 1000;
        engine.tick();
      }
    },
  };
}

test('end of song: quiet takes lyrics off the screen, then the song ends', () => {
  const h = engineHarness();
  h.engine.lock('sample-lantern');
  h.wait(29_000);
  assert.ok(!h.types().includes('quiet'));
  h.wait(2_000);
  assert.ok(h.types().includes('quiet'));
  assert.equal(h.engine.showing(), false);
  assert.ok(h.engine.locked, 'still the same song in case it resumes');
  h.wait(46_000);
  assert.ok(h.types().includes('ended'));
  assert.equal(h.engine.locked, null);
});

test('end of song: talking counts as no match', () => {
  const h = engineHarness();
  h.engine.lock('sample-lantern');
  for (let i = 0; i < 7; i++) {
    h.sing('Let us think about what this message means for our lives this week', 5000);
    h.engine.tick();
  }
  assert.ok(h.types().includes('quiet'));
});

test('a pause in the song resumes in place', () => {
  const h = engineHarness();
  h.engine.lock('sample-lantern');
  h.sing('Carried by the evening tide');
  h.wait(35_000);
  assert.equal(h.engine.showing(), false);
  h.sing('Every window on the harbor glowing');
  assert.ok(h.types().includes('resume'));
  assert.equal(h.engine.showing(), true);
  assert.equal(h.engine.position().index, 2);
});

test('song change: another song takes over once the current one goes quiet', () => {
  const h = engineHarness();
  h.engine.lock('sample-lantern');
  h.sing('Carried by the evening tide');
  h.sing('Golden apples hanging in the orchard', 11_000);
  h.sing('Sweetness on the morning breeze');
  h.sing('Every branch is bending with the blossom');
  const change = h.events.find((e) => e.type === 'songChange');
  assert.equal(change?.songId, 'sample-orchard');
});

test('song change: a brief match on another song does not take over', () => {
  const h = engineHarness();
  h.engine.lock('sample-lantern');
  h.sing('Carried by the evening tide');
  h.sing('Golden apples hanging in the orchard');
  h.sing('Every window on the harbor glowing');
  h.sing('Sweetness on the morning breeze');
  h.sing('Calling all the sailors home tonight');
  assert.ok(!h.types().includes('songChange'));
});

test('song change is flagged when the operator chose the current song', () => {
  const h = engineHarness();
  h.engine.lock('sample-lantern', { byOperator: true });
  h.sing('Golden apples hanging in the orchard', 11_000);
  h.sing('Sweetness on the morning breeze');
  h.sing('Every branch is bending with the blossom');
  assert.equal(h.events.find((e) => e.type === 'songChange')?.byOperator, true);
});

test('setPosition moves the tracker when the operator takes over', () => {
  const h = engineHarness();
  h.engine.lock('sample-lantern');
  h.engine.setPosition(9);
  assert.equal(h.engine.position().index, 9);
});
