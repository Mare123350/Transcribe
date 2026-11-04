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
