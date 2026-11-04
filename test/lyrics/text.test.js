import test from 'node:test';
import assert from 'node:assert/strict';
import { alignLine, cleanTranscript, normalizeWords, phoneticKey, wordSimilarity } from '../../shared/lyrics/text.js';

const words = (text) => normalizeWords(text).join(' ');
const line = (text) => normalizeWords(text).map((word) => ({ word, weight: 1 }));

test('normalization: case, punctuation and contractions', () => {
  assert.equal(words('We\'re SINGING, "Louder!"'), 'we are singing louder');
  assert.equal(words("I can't, won't, don't"), 'i can not will not do not');
  assert.equal(words('O’er the hills'), 'over the hills');
  assert.equal(words("Let's go, it's time"), 'let us go it is time');
  assert.equal(words("'Tis the night"), 'it is the night');
  assert.equal(words("singin' in the rain"), 'singing in the rain');
  assert.equal(words("The river's edge"), 'the river edge');
  assert.equal(words('gonna wanna'), 'going to want to');
});

test('normalization: filler is removed', () => {
  assert.equal(words('Oh oh yeah, ooh the river, hey, mmm'), 'the river');
  assert.equal(words('oh yeah'), '');
});

test('normalization: spellings and numbers line up', () => {
  assert.equal(words('Alleluia'), words('Hallelujah'));
  assert.equal(words('John 3:16'), 'john three sixteen');
  assert.equal(words('Psalm 119'), 'psalm one hundred nineteen');
  assert.equal(words('20'), 'twenty');
});

test('similarity: exact, sound-alike, near miss, different', () => {
  assert.equal(wordSimilarity('river', 'river'), 1);
  assert.ok(wordSimilarity('harbor', 'harbour') >= 0.8);
  assert.ok(wordSimilarity('grace', 'graze') >= 0.8);
  assert.ok(wordSimilarity('lantern', 'lanterns') >= 0.8);
  assert.equal(wordSimilarity('river', 'mountain'), 0);
  assert.equal(wordSimilarity('the', 'to'), 0, 'short words need to match exactly');
  assert.equal(phoneticKey('phone'), phoneticKey('fone'));
});

test('alignment: exact line inside other words', () => {
  const heard = normalizeWords('and then we sing across the morning bay right now');
  const match = alignLine(line('sing across the morning bay'), heard);
  assert.ok(match.coverage > 0.99);
  assert.equal(match.words, 5);
  assert.deepEqual(heard.slice(match.start, match.end + 1), normalizeWords('sing across the morning bay'));
});

test('alignment: tolerates wrong, missing and extra words', () => {
  const target = line('every window on the harbor glowing');
  assert.ok(alignLine(target, normalizeWords('every widow on the harbor glowing')).coverage > 0.75, 'wrong word');
  assert.ok(alignLine(target, normalizeWords('every window the harbor glowing')).coverage > 0.75, 'missing word');
  assert.ok(alignLine(target, normalizeWords('every window on the old harbor glowing')).coverage > 0.9, 'extra word');
});

test('alignment: unrelated words score low', () => {
  assert.ok(alignLine(line('every window on the harbor glowing'), normalizeWords('please open your hands and pray with me')).coverage < 0.3);
});

test('alignment: words in the wrong order only partly match', () => {
  assert.ok(alignLine(line('sing across the morning bay'), normalizeWords('bay morning the across sing')).coverage < 0.5);
});

test('clean-up: invented phrases and noise tags are removed', () => {
  assert.deepEqual(cleanTranscript('[Music]'), []);
  assert.deepEqual(cleanTranscript('(applause)'), []);
  assert.deepEqual(cleanTranscript('Music'), []);
  assert.deepEqual(cleanTranscript('♪ ♪'), []);
  assert.deepEqual(cleanTranscript('the river thank you for watching flows'), ['the', 'river', 'flows']);
  assert.deepEqual(cleanTranscript('Music in the river'), ['music', 'in', 'the', 'river'], 'a real lyric can still say music');
});

test('clean-up: runaway repeats are cut back, but ordinary repeats stay', () => {
  const looped = cleanTranscript('hold on '.repeat(12));
  assert.equal(looped.join(' '), 'hold on hold on hold on');
  assert.equal(cleanTranscript('holy holy holy').length, 3);
  assert.equal(cleanTranscript('go go go go go go').length, 3);
});

test('clean-up: low-confidence words are dropped when the engine reports them', () => {
  const result = cleanTranscript('ignored', {
    words: [{ word: 'river', confidence: 0.9 }, { word: 'banana', confidence: 0.1 }, { word: 'flows', confidence: 0.6 }],
  });
  assert.deepEqual(result, ['river', 'flows']);
});
