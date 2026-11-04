import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { runReplay } from '../../shared/lyrics/replay.js';

const folder = new URL('../fixtures/replay/', import.meta.url).pathname;
const load = (name) => JSON.parse(readFileSync(`${folder}${name}.json`, 'utf8'));
const replay = (name, options) => runReplay(load(name), options);

test('every transcript runs with no wrong detections', () => {
  for (const file of readdirSync(folder)) {
    const result = replay(file.replace('.json', ''));
    assert.equal(result.wrongDetections, 0, `${file}: ${JSON.stringify(result.wrong)}`);
  }
});

test('a clean song is found within three lines', () => {
  const result = replay('clean-full-song');
  assert.equal(result.missed, 0);
  assert.ok(result.meanDetectMs <= 16_000, `took ${result.meanDetectMs}`);
});

test('noisy transcripts with misheard words and missing lines still find the song', () => {
  for (const name of ['noisy-from-setlist', 'noisy-from-library']) {
    const result = replay(name);
    assert.equal(result.missed, 0, name);
    assert.ok(result.meanDetectMs <= 40_000, `${name} took ${result.meanDetectMs}`);
  }
});

test('a line shared between songs never locks anything', () => {
  assert.deepEqual(replay('shared-line-only').locks, []);
});

test('talking never locks a song', () => {
  assert.deepEqual(replay('talk-only').locks, []);
});

test('two songs in a row are both found', () => {
  const result = replay('two-songs-with-a-gap');
  assert.equal(result.missed, 0, JSON.stringify(result.songs));
});

test('line tracking: clean song', () => {
  const result = replay('clean-full-song');
  assert.ok(result.lineSamples > 10);
  assert.ok(result.lineExact >= 0.95, `exact ${result.lineExact}`);
});

test('line tracking: noisy song with missing lines', () => {
  const result = replay('noisy-from-setlist');
  assert.ok(result.lineClose >= 0.8, `within one line ${result.lineClose}`);
});

test('line tracking: repeated choruses', () => {
  const result = replay('repeated-choruses');
  assert.ok(result.lineExact >= 0.8, `exact ${result.lineExact}`);
});

test('line tracking: skipped and out-of-order sections', () => {
  const result = replay('skipped-and-out-of-order');
  assert.ok(result.lineClose >= 0.8, `within one line ${result.lineClose}`);
});

test('line tracking: vamping, then moving on', () => {
  const result = replay('vamp-then-move-on');
  assert.ok(result.lineExact >= 0.9, `exact ${result.lineExact}`);
});

test('lyrics come off the screen after a song ends', () => {
  const result = replay('song-ends-into-talk');
  assert.ok(result.clears.some((clear) => clear.type === 'quiet'));
  assert.ok(result.clears.some((clear) => clear.type === 'ended'));
  assert.ok(result.staleMs <= 31_000, `stale for ${result.staleMs}ms`);
});

test('line tracking: results cut anywhere stay within a line on clean audio', () => {
  const result = replay('cut-anywhere-clean');
  assert.ok(result.lineClose >= 0.95, `within one line ${result.lineClose}`);
});

test('line tracking: results cut anywhere, with heavy noise, stay mostly close', () => {
  const result = replay('cut-anywhere-noisy');
  assert.ok(result.lineClose >= 0.7, `within one line ${result.lineClose}`);
});
