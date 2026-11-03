import test from 'node:test';
import assert from 'node:assert/strict';
import { paginate } from '../shared/pagination.js';
import { DEMO_TRANSCRIPTS } from '../shared/demoTranscripts.js';
import { harness } from './helpers.js';

const fitsChars = (limit) => (page) => page.reduce((n, v) => n + v.text.length, 0) <= limit;
const verse = (n, text) => ({ verse: n, text });

test('a short passage stays on one page', () => {
  const pages = paginate([verse(1, 'one two'), verse(2, 'three four')], fitsChars(100));
  assert.equal(pages.length, 1);
  assert.deepEqual(pages[0].map((v) => v.verse), [1, 2]);
});

test('verses move whole to the next page when they can', () => {
  const pages = paginate([verse(1, 'a'.repeat(60)), verse(2, 'b'.repeat(60)), verse(3, 'c'.repeat(30))], fitsChars(100));
  assert.deepEqual(pages.map((p) => p.map((v) => v.verse)), [[1], [2, 3]]);
});

test('a verse too long for one page is split at word boundaries with nothing lost', () => {
  const text = Array.from({ length: 80 }, (_, i) => `word${i}`).join(' ');
  const pages = paginate([verse(1, 'short'), verse(2, text)], fitsChars(100));
  assert.ok(pages.length > 2);
  const pieces = pages.flat().filter((v) => v.verse === 2);
  assert.equal(pieces.map((p) => p.text).join(' '), text);
  assert.equal(pieces[0].continued, undefined);
  assert.ok(pieces.slice(1).every((p) => p.continued));
  for (const page of pages) assert.ok(fitsChars(100)(page));
});

test('a single word wider than a page still appears', () => {
  const pages = paginate([verse(1, 'x'.repeat(200))], fitsChars(10));
  assert.equal(pages.flat()[0].text.length, 200);
});

test('empty input gives no pages', () => {
  assert.deepEqual(paginate([], fitsChars(10)), []);
});

function runDemo(id) {
  const h = harness();
  for (const line of DEMO_TRANSCRIPTS.find((d) => d.id === id).lines) {
    h.detector.addFinal(line.say);
    h.advance(line.pause ?? 400);
  }
  h.advance(5000);
  return h.log;
}

test('demo: the Sunday sermon detects every form, confirmed, with the repeat suppressed', () => {
  const log = runDemo('sermon');
  assert.deepEqual(log.detections.map((d) => [d.key, d.status]), [
    ['JHN.3.16', 'confirmed'],
    ['1CO.13.4-7', 'confirmed'],
    ['ROM.8.28', 'confirmed'],
    ['PSA.23', 'confirmed'],
  ]);
  assert.deepEqual(log.repeats.map((d) => d.key), ['JHN.3.16']);
});

test('demo: tricky cases behave as described', () => {
  const log = runDemo('tricky');
  assert.deepEqual(log.detections.map((d) => [d.key, d.status]), [
    ['ROM.8.28', 'confirmed'],
    ['1CO.13|2CO.13', 'suggestion'],
    ['PHP.4.13', 'suggestion'],
    ['JHN.35', 'invalid'],
    ['PSA.151', 'invalid'],
    ['JHN.3.16', 'confirmed'],
    ['JHN.3.17', 'suggestion'],
    ['MRK.2', 'suggestion'],
  ]);
  assert.equal(log.repeats.length, 2);
});

test('demo: long passages', () => {
  const log = runDemo('long');
  assert.deepEqual(log.detections.map((d) => d.key), ['PSA.119', 'PSA.117', 'LAM.3.22-23']);
});
