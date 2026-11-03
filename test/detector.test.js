import test from 'node:test';
import assert from 'node:assert/strict';
import { harness } from './helpers.js';
import { refKey } from '../shared/references.js';

test('segmented: a reference split across final segments is detected whole', () => {
  const h = harness();
  h.detector.addFinal('please turn to Romans');
  h.advance(400);
  h.detector.addFinal('eight twenty eight and notice the promise');
  h.advance(5000);
  assert.deepEqual(h.keys(), ['ROM.8.28']);
});

test('segmented: no premature whole chapter while the verse is still coming', () => {
  const h = harness();
  h.detector.addFinal('John chapter three');
  h.advance(600);
  assert.deepEqual(h.keys(), [], 'should still be holding');
  h.detector.addFinal('verse sixteen');
  h.advance(5000);
  assert.deepEqual(h.keys(), ['JHN.3.16']);
});

test('segmented: split at every position gives the same answer', () => {
  const words = 'turn to First Corinthians thirteen verses four to seven today'.split(' ');
  for (let split = 1; split < words.length; split++) {
    const h = harness();
    h.detector.addFinal(words.slice(0, split).join(' '));
    h.advance(500);
    h.detector.addFinal(words.slice(split).join(' '));
    h.advance(5000);
    assert.deepEqual(h.keys(), ['1CO.13.4-7'], `split at ${split}`);
  }
});

test('segmented: a split number compound rejoins', () => {
  const h = harness();
  h.detector.addFinal('Romans eight twenty');
  h.advance(300);
  h.detector.addFinal('eight');
  h.advance(5000);
  assert.deepEqual(h.keys(), ['ROM.8.28']);
});

test('segmented: punctuation at a segment boundary does not break a reference', () => {
  const h = harness();
  h.detector.addFinal('Turn to Romans.');
  h.advance(300);
  h.detector.addFinal('Eight twenty eight.');
  h.advance(5000);
  assert.deepEqual(h.keys(), ['ROM.8.28']);
});

test('segmented: a held reference settles when nothing more comes', () => {
  const h = harness();
  h.detector.addFinal('First Corinthians thirteen');
  h.advance(1000);
  assert.deepEqual(h.keys(), []);
  h.advance(300);
  assert.deepEqual(h.keys(), ['1CO.13']);
});

test('segmented: a long silence stops a book and a stray number from joining', () => {
  const h = harness();
  h.detector.addFinal('and that is the message of Romans');
  h.advance(20_000);
  h.detector.addFinal('eight people came forward last week');
  h.advance(5000);
  assert.deepEqual(h.keys(), []);
});

test('interim: interim text never triggers a detection', () => {
  const h = harness();
  for (const partial of ['John', 'John three', 'John three sixteen', 'John three sixteen for God']) {
    h.detector.addInterim(partial);
    h.advance(200);
  }
  h.advance(10_000);
  assert.deepEqual(h.keys(), []);
  assert.ok(h.log.tentative.some((list) => list.some((d) => d.key === 'JHN.3.16')), 'shown as tentative');
});

test('interim: growing interims then a final produce exactly one detection', () => {
  const h = harness();
  for (const partial of ['John', 'John three', 'John three six', 'John three sixteen']) {
    h.detector.addInterim(partial);
    h.advance(100);
  }
  h.detector.addFinal('John three sixteen for God so loved');
  h.advance(5000);
  assert.deepEqual(h.keys(), ['JHN.3.16']);
});

test('interim: a revised interim leaves no trace', () => {
  const h = harness();
  h.detector.addInterim('John three sixteen');
  h.advance(100);
  h.detector.addInterim('Joan through sixteen');
  h.advance(100);
  h.detector.addFinal('Joan went through sixteen towns');
  h.advance(5000);
  assert.deepEqual(h.keys(), []);
  assert.deepEqual(h.log.tentative.at(-1), []);
});

test('interim: interim words release a held reference straight away', () => {
  const h = harness();
  h.detector.addFinal('John three sixteen');
  h.advance(100);
  assert.deepEqual(h.keys(), []);
  h.detector.addInterim('for God so');
  assert.deepEqual(h.keys(), ['JHN.3.16']);
});

test('interim: an interim that extends a held reference keeps it held', () => {
  const h = harness();
  h.detector.addFinal('John chapter three');
  h.advance(300);
  h.detector.addInterim('verse six');
  h.advance(300);
  h.detector.addInterim('verse sixteen');
  h.advance(300);
  assert.deepEqual(h.keys(), [], 'still growing');
  h.detector.addFinal('verse sixteen');
  h.advance(5000);
  assert.deepEqual(h.keys(), ['JHN.3.16']);
});

test('duplicates: rescans of the buffer do not repeat a detection', () => {
  const h = harness();
  h.detector.addFinal('John three sixteen is where we begin');
  for (let i = 0; i < 10; i++) {
    h.detector.addInterim(`and then we go on ${i}`);
    h.detector.addFinal(`and we keep talking some more ${i}`);
    h.advance(500);
  }
  assert.deepEqual(h.keys(), ['JHN.3.16']);
  assert.equal(h.log.repeats.length, 0);
});

test('duplicates: the preacher repeating a reference does not redisplay it', () => {
  const h = harness();
  h.detector.addFinal('John three sixteen, John three sixteen, I said John chapter three verse sixteen.');
  h.advance(5000);
  assert.deepEqual(h.keys(), ['JHN.3.16']);
  assert.equal(h.log.repeats.length, 2);
});

test('duplicates: the engine re-sending the same final does not redisplay it', () => {
  const h = harness();
  h.detector.addFinal('Romans eight twenty eight');
  h.advance(2000);
  h.detector.addFinal('Romans eight twenty eight');
  h.advance(5000);
  assert.deepEqual(h.keys(), ['ROM.8.28']);
});

test('duplicates: the same reference after the cooldown counts again', () => {
  const h = harness({ cooldownMs: 30_000 });
  h.detector.addFinal('Romans eight twenty eight');
  h.advance(2000);
  h.advance(40_000);
  h.detector.addFinal('Romans eight twenty eight');
  h.advance(5000);
  assert.deepEqual(h.keys(), ['ROM.8.28', 'ROM.8.28']);
});

test('duplicates: different verses in one chapter are separate', () => {
  const h = harness();
  h.detector.addFinal('John three sixteen and also John three seventeen today');
  h.advance(5000);
  assert.deepEqual(h.keys(), ['JHN.3.16', 'JHN.3.17']);
});

test('several references in one segment come out in order', () => {
  const h = harness();
  h.detector.addFinal('compare Genesis one one with John one one and Hebrews eleven three.');
  h.advance(5000);
  assert.deepEqual(h.keys(), ['GEN.1.1', 'JHN.1.1', 'HEB.11.3']);
});

test('context: a bare verse after a reference is a suggestion in that chapter', () => {
  const h = harness();
  h.detector.addFinal('John three sixteen is the promise');
  h.advance(2000);
  h.detector.addFinal('and look down at verse seventeen right there');
  h.advance(5000);
  const last = h.log.detections.at(-1);
  assert.equal(last.key, 'JHN.3.17');
  assert.equal(last.status, 'suggestion');
});

test('context: a bare chapter uses the previous book, as a suggestion', () => {
  const h = harness();
  h.detector.addFinal('Romans eight twenty eight is the promise');
  h.advance(2000);
  h.detector.addFinal('and over in chapter twelve verse one we see');
  h.advance(5000);
  const last = h.log.detections.at(-1);
  assert.equal(last.key, 'ROM.12.1');
  assert.equal(last.status, 'suggestion');
});

test('context: a bare verse with no recent reference is ignored', () => {
  const h = harness({ contextMs: 60_000 });
  h.detector.addFinal('verse seventeen is lovely');
  h.advance(5000);
  assert.deepEqual(h.keys(), []);
  h.detector.addFinal('John three sixteen is the promise');
  h.advance(120_000);
  h.detector.addFinal('and look at verse seventeen today');
  h.advance(5000);
  assert.deepEqual(h.keys(), ['JHN.3.16']);
});

test('invalid references flow through as invalid and are deduplicated', () => {
  const h = harness();
  h.detector.addFinal('John thirty five is not real. John thirty five again.');
  h.advance(5000);
  assert.equal(h.log.detections.length, 1);
  assert.equal(h.log.detections[0].status, 'invalid');
  assert.deepEqual(h.log.detections[0].refs.map(refKey), ['JHN.35']);
});

test('flush reports anything still held', () => {
  const h = harness();
  h.detector.addFinal('Psalm twenty three');
  assert.deepEqual(h.keys(), []);
  h.detector.flush();
  assert.deepEqual(h.keys(), ['PSA.23']);
});

test('a long sermon stays bounded and keeps detecting', () => {
  const h = harness({ cooldownMs: 0 });
  const filler = 'and the people of the church gathered together to hear the word of the Lord today '.repeat(4);
  for (let i = 0; i < 300; i++) {
    h.detector.addFinal(`${filler} Romans eight twenty eight ${filler}`);
    h.advance(1000);
  }
  assert.equal(h.log.detections.length, 300);
  assert.ok(h.detector.finalText.length <= 2_000 + filler.length * 2 + 100);
});

test('the matched phrase is taken from the raw transcript', () => {
  const h = harness();
  h.detector.addFinal('Turn with me to First Corinthians thirteen, verses four to seven, please.');
  h.advance(5000);
  assert.equal(h.log.detections[0].phrase, 'First Corinthians thirteen, verses four to seven');
});
