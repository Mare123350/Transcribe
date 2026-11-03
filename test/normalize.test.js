import test from 'node:test';
import assert from 'node:assert/strict';
import { normalizeTranscript } from '../shared/normalize.js';

const norm = (text, options) => normalizeTranscript(text, options).text;

test('spoken numbers become digits', () => {
  const cases = {
    'john three sixteen': 'john 3 16',
    'romans eight twenty-eight': 'romans 8 28',
    'romans eight twenty eight': 'romans 8 28',
    'psalm twenty three': 'psalm 23',
    'matthew twenty eight nineteen': 'matthew 28 19',
    'genesis twelve three': 'genesis 12 3',
    'psalm one hundred nineteen': 'psalm 119',
    'psalm one hundred and nineteen': 'psalm 119',
    'psalm a hundred and three': 'psalm 103',
    'psalm one oh five': 'psalm 105',
    'psalm one hundred': 'psalm 100',
    'isaiah fifty three five': 'isaiah 53 5',
    'proverbs forty': 'proverbs 40',
    'revelation twenty one four': 'revelation 21 4',
  };
  for (const [spoken, expected] of Object.entries(cases)) assert.equal(norm(spoken), expected, spoken);
});

test('digits and written forms pass through in canonical form', () => {
  assert.equal(norm('John 3:16'), 'john 3 verse 16');
  assert.equal(norm('1 Corinthians 13:4-7.'), '1 corinthians 13 verse 4 to 7');
  assert.equal(norm('Romans 8.28'), 'romans 8 verse 28');
  assert.equal(norm('Psalm 23'), 'psalm 23');
});

test('numbered books in every spoken and written form', () => {
  const cases = {
    'first corinthians thirteen': '1 corinthians 13',
    '1st corinthians 13': '1 corinthians 13',
    '1 corinthians 13': '1 corinthians 13',
    'one corinthians thirteen': '1 corinthians 13',
    'I Corinthians 13': '1 corinthians 13',
    'second timothy one seven': '2 timothy 1 7',
    'two timothy one seven': '2 timothy 1 7',
    'II Timothy 1:7': '2 timothy 1 verse 7',
    'third john four': '3 john 4',
    '3 john 4': '3 john 4',
    'second kings five': '2 kings 5',
    'first samuel seventeen': '1 samuel 17',
    'second chronicles seven fourteen': '2 chronicles 7 14',
    'first thessalonians five': '1 thessalonians 5',
    'second peter three nine': '2 peter 3 9',
    'the first letter to the corinthians thirteen': 'the 1 corinthians 13',
    'second epistle of peter three': '2 peter 3',
  };
  for (const [spoken, expected] of Object.entries(cases)) assert.equal(norm(spoken), expected, spoken);
});

test('a number after a book is not mistaken for the next book\'s prefix', () => {
  assert.equal(norm('john three john four'), 'john 3 john 4');
  assert.equal(norm('romans eight twenty two timothy one seven'), 'romans 8 20 2 timothy 1 7');
});

test('book name variations and transcription errors', () => {
  const cases = {
    'psalms twenty three': 'psalm 23',
    'revelations three twenty': 'revelation 3 20',
    'phillipians four thirteen': 'philippians 4 13',
    'philippines four thirteen': 'philippians 4 13',
    'songs of solomon two': 'song of solomon 2',
    'song of songs two': 'song of solomon 2',
    'gospel of john three': 'john 3',
    'gospel according to saint matthew five': 'matthew 5',
    'the book of isaiah six': 'isaiah 6',
    'mathew five': 'matthew 5',
    'isiah forty': 'isaiah 40',
    'acts of the apostles two': 'acts 2',
    'habakuk two four': 'habakkuk 2 4',
    'ecclesiastics three': 'ecclesiastes 3',
    'zachariah four six': 'zechariah 4 6',
    'jon three sixteen': 'john 3 16',
    'sam twenty three': 'psalm 23',
    "psalm's twenty three": 'psalm 23',
  };
  for (const [spoken, expected] of Object.entries(cases)) assert.equal(norm(spoken), expected, spoken);
});

test('misspellings outside the alias list are caught by fuzzy matching and flagged', () => {
  const { tokens } = normalizeTranscript('Lamentasions three twenty two');
  assert.equal(tokens[0].text, 'lamentations');
  assert.equal(tokens[0].book.fuzzy, true);
});

test('fuzzy matching only applies when a number follows', () => {
  assert.equal(norm('the revolutionary spirit'), 'the revolutionary spirit');
  assert.equal(norm('lamentasions are sad'), 'lamentasions are sad');
});

test('ordinals in natural speech', () => {
  assert.equal(norm('the third chapter of john'), 'the chapter 3 of john');
  assert.equal(norm('the twenty third psalm'), 'the psalm 23');
  assert.equal(norm('the hundred and nineteenth psalm'), 'the psalm 119');
  assert.equal(norm('the sixteenth verse'), 'the verse 16');
});

test('range words and verse-word errors are canonicalized', () => {
  assert.equal(norm('verses four through seven'), 'verses 4 to 7');
  assert.equal(norm('verses four thru seven'), 'verses 4 to 7');
  assert.equal(norm('versus four to seven'), 'verses 4 to 7');
});

test('"for" after a chapter stays a word', () => {
  assert.equal(norm('john three for god so loved'), 'john 3 for god so loved');
});

test('homophones only count as numbers in a number context', () => {
  assert.equal(norm('romans ate twenty ate'), 'romans 8 20 8');
  assert.equal(norm('we ate together and won'), 'we ate together and won');
});

test('abbreviations are only accepted in manual search', () => {
  assert.equal(norm('1 cor 13:4-7', { manual: true }), '1 corinthians 13 verse 4 to 7');
  assert.equal(norm('1 sam 3', { manual: true }), '1 samuel 3');
  assert.equal(norm('rom 8 28', { manual: true }), 'romans 8 28');
  assert.equal(norm('rom 8 28'), 'rom 8 28');
});

test('tokens map back to the raw text', () => {
  const raw = 'Turn to First Corinthians thirteen now';
  const { tokens } = normalizeTranscript(raw);
  const book = tokens.find((t) => t.kind === 'book');
  assert.equal(raw.slice(book.start, book.end), 'First Corinthians');
});
