import test from 'node:test';
import assert from 'node:assert/strict';
import { parseManualReference } from '../shared/parser.js';
import { formatRef, refKey, adjacentRef, parseRefKey, verseRef, chapterRef } from '../shared/references.js';
import { validateRef } from '../shared/validate.js';
import { detect, KJV } from './helpers.js';

const expectOne = (text, key, status = 'confirmed') => {
  const found = detect(text);
  assert.equal(found.length, 1, `${text}: ${JSON.stringify(found.map((d) => d.key))}`);
  assert.equal(found[0].key, key, text);
  assert.equal(found[0].status, status, `${text}: ${found[0].reasons}`);
  return found[0];
};

test('the spoken forms from the spec', () => {
  expectOne('John three sixteen.', 'JHN.3.16');
  expectOne('John chapter three, verse sixteen.', 'JHN.3.16');
  expectOne('First Corinthians thirteen, verses four to seven.', '1CO.13.4-7');
  expectOne('Romans eight twenty-eight.', 'ROM.8.28');
  expectOne('Psalm twenty-three.', 'PSA.23');
});

test('references embedded in ordinary sentences', () => {
  expectOne('please turn with me to Hebrews eleven one and read along', 'HEB.11.1');
  expectOne('as it says in Ephesians two verse eight about grace', 'EPH.2.8');
  expectOne('Isaiah fifty three is a chapter I love', 'ISA.53');
});

test('whole chapters', () => {
  expectOne('Psalm one hundred', 'PSA.100');
  expectOne('Romans chapter eight', 'ROM.8');
  expectOne('First Corinthians thirteen', '1CO.13');
  expectOne('John chapter three', 'JHN.3');
  expectOne('the gospel of John three', 'JHN.3');
  expectOne('the twenty third psalm', 'PSA.23');
});

test('verse ranges in many forms', () => {
  expectOne('Romans eight twenty eight to thirty', 'ROM.8.28-30');
  expectOne('Romans eight verses twenty eight through thirty', 'ROM.8.28-30');
  expectOne('Proverbs three five and six', 'PRO.3.5-6');
  expectOne('Proverbs three verses five and six', 'PRO.3.5-6');
  expectOne('Proverbs three, verses five, six', 'PRO.3.5-6');
  expectOne('Proverbs 3:5-6', 'PRO.3.5-6');
  expectOne('First Corinthians 13:4–7', '1CO.13.4-7');
  expectOne('Matthew five verse three to verse twelve', 'MAT.5.3-12');
  expectOne('John chapter three beginning at verse sixteen', 'JHN.3.16');
});

test('non-contiguous verses become separate detections', () => {
  const found = detect('Genesis one verses one and twenty seven');
  assert.deepEqual(found.map((d) => d.key), ['GEN.1.1', 'GEN.1.27']);
});

test('a verse list stops at numbers that are not verses', () => {
  const found = detect('John three sixteen and three other things to remember');
  assert.deepEqual(found.map((d) => d.key), ['JHN.3.16']);
});

test('natural word orders', () => {
  expectOne('the third chapter of John', 'JHN.3');
  expectOne('the third chapter of John, verse sixteen', 'JHN.3.16');
  expectOne('verse sixteen of John chapter three', 'JHN.3.16');
  expectOne('verses four to seven of First Corinthians thirteen', '1CO.13.4-7');
});

test('numbered books', () => {
  expectOne('Second Timothy one seven', '2TI.1.7');
  expectOne('First John four eight', '1JN.4.8');
  expectOne('1 John 4:8', '1JN.4.8');
  expectOne('Second Chronicles seven fourteen', '2CH.7.14');
  expectOne('Second Peter three nine', '2PE.3.9');
  expectOne('First Samuel seventeen', '1SA.17');
});

test('one-chapter books', () => {
  expectOne('Third John four', '3JN.1.4');
  expectOne('Philemon six', 'PHM.1.6');
  expectOne('Jude verse twenty four', 'JUD.1.24');
  expectOne('Jude one twenty', 'JUD.1.20');
  expectOne('Obadiah one three', 'OBA.1.3');
});

test('Psalms said without "hundred"', () => {
  expectOne('Psalm one nineteen', 'PSA.119');
  expectOne('Psalm one twenty one', 'PSA.121');
  expectOne('Psalm one eighteen six', 'PSA.118.6');
  expectOne('Psalm one oh five', 'PSA.105');
  expectOne('Psalm one five', 'PSA.1.5');
  expectOne('Psalm one nineteen verse one oh five', 'PSA.119.105');
});

test('a compound number offers the split reading as an alternate', () => {
  const found = expectOne('Psalm twenty three', 'PSA.23');
  assert.deepEqual(found.alternates.map(refKey), ['PSA.20.3']);
});

test('falls back to the split reading when the chapter does not exist, and asks', () => {
  expectOne('John twenty eight', 'JHN.20.8', 'suggestion');
});

test('ambiguous: a numbered book without its number offers each valid book', () => {
  const [found] = detect('Corinthians thirteen love never fails');
  assert.equal(found.status, 'suggestion');
  assert.deepEqual(found.refs.map(refKey), ['1CO.13', '2CO.13']);
});

test('ambiguous: validation narrows the options but it still asks', () => {
  const [found] = detect('Corinthians fifteen is about the resurrection');
  assert.equal(found.status, 'suggestion');
  assert.deepEqual(found.refs.map(refKey), ['1CO.15']);
});

test('ambiguous: mishearings need confirmation', () => {
  const found = expectOne('Philippines four thirteen', 'PHP.4.13', 'suggestion');
  assert.match(found.reasons[0], /philippines/);
  expectOne('Lamentasions three twenty two', 'LAM.3.22', 'suggestion');
  expectOne('Sam twenty three', 'PSA.23', 'suggestion');
});

test('ambiguous: a name and one number could be ordinary speech', () => {
  expectOne('then we read Mark two', 'MRK.2', 'suggestion');
  expectOne('John three', 'JHN.3', 'suggestion');
  expectOne('James five', 'JAS.5', 'suggestion');
  expectOne('Jude three', 'JUD.1.3', 'suggestion');
});

test('ambiguous: a passage crossing into another chapter is flagged', () => {
  expectOne('John three sixteen to four two', 'JHN.3.16', 'suggestion');
});

test('ordinary speech with names and numbers is not a reference', () => {
  const quiet = [
    'Peter denied him three times that night',
    'and John three times ran back',
    'Mark two people came to me',
    'James five years ago told me',
    'Pastor John three weeks ago said',
    'my friend Luke twelve of us went',
    'Numbers ten or so',
    'Peter, James and John, three of the disciples',
    'I was speaking with Mark. Two people came over',
    'for God so loved the world',
    'chapter five of my life',
    'verse seventeen is great',
    'in the first place and the second place',
    'one two three four five',
    'Romans were everywhere in those days',
    'the Book of Romans',
  ];
  for (const line of quiet) {
    assert.deepEqual(detect(line).map((d) => d.key), [], line);
  }
});

test('invalid references are reported as invalid with a reason', () => {
  const cases = [
    ['John thirty five', /no chapter 35/],
    ['Romans twenty eight', /no chapter 28/],
    ['John three ninety', /no verse 90/],
    ['Psalm one hundred and fifty one', /no chapter 151/],
    ['Psalm twenty three verses four to nine', /no verse 9/],
  ];
  for (const [line, reason] of cases) {
    const [found] = detect(line);
    assert.equal(found?.status, 'invalid', line);
    assert.match(found.reasons[0], reason);
  }
});

test('validation uses the selected translation, not one fixed table', () => {
  const web = { exact: true, books: { ...KJV.books, ROM: KJV.books.ROM.map((n, i) => (i === 15 ? 24 : n)) } };
  assert.equal(validateRef(verseRef('ROM', 16, 27), KJV).ok, true);
  assert.equal(validateRef(verseRef('ROM', 16, 27), web).ok, false);
  const partial = { exact: true, books: { JHN: KJV.books.JHN } };
  assert.match(validateRef(chapterRef('ROM', 1), partial).reason, /not in this translation/);
});

test('API translations pass unknown verses on for the provider to decide', () => {
  const approximate = { exact: false, books: KJV.books };
  const result = validateRef(verseRef('3JN', 1, 15), approximate); // 15 verses in the ESV, 14 in the KJV
  assert.deepEqual(result, { ok: true, unverified: true });
  assert.equal(validateRef(chapterRef('JHN', 99), approximate).ok, false);
});

test('manual search understands abbreviations and skips speech guards', () => {
  const read = (text) => parseManualReference(text, KJV).refs?.map(refKey);
  assert.deepEqual(read('1 cor 13:4-7'), ['1CO.13.4-7']);
  assert.deepEqual(read('jn 3 16'), ['JHN.3.16']);
  assert.deepEqual(read('Mark 2'), ['MRK.2']);
  assert.deepEqual(read('first corinthians thirteen'), ['1CO.13']);
  assert.deepEqual(read('ps 23'), ['PSA.23']);
  assert.deepEqual(read('corinthians 13'), ['1CO.13', '2CO.13']);
  assert.match(parseManualReference('John 99', KJV).error, /no chapter 99/);
  assert.match(parseManualReference('hello there', KJV).error, /Couldn't read/);
});

test('formatting and keys round-trip', () => {
  assert.equal(formatRef(verseRef('JHN', 3, 16)), 'John 3:16');
  assert.equal(formatRef(verseRef('1CO', 13, 4, 7)), '1 Corinthians 13:4–7');
  assert.equal(formatRef(chapterRef('PSA', 23)), 'Psalm 23');
  assert.equal(formatRef(chapterRef('JUD', 1)), 'Jude');
  for (const key of ['JHN.3', 'JHN.3.16', '1CO.13.4-7']) assert.equal(refKey(parseRefKey(key)), key);
  for (const bad of ['', 'JHN', 'john.3', 'JHN.3.16-', '../etc']) assert.equal(parseRefKey(bad), null);
});

test('previous and next verse navigation crosses chapters within a book', () => {
  const step = (ref, direction) => {
    const next = adjacentRef(ref, direction, KJV);
    return next && refKey(next);
  };
  assert.equal(step(verseRef('JHN', 3, 16), 1), 'JHN.3.17');
  assert.equal(step(verseRef('JHN', 3, 16), -1), 'JHN.3.15');
  assert.equal(step(verseRef('1CO', 13, 4, 7), 1), '1CO.13.8');
  assert.equal(step(verseRef('1CO', 13, 4, 7), -1), '1CO.13.3');
  assert.equal(step(verseRef('JHN', 3, 36), 1), 'JHN.4.1');
  assert.equal(step(verseRef('JHN', 4, 1), -1), 'JHN.3.36');
  assert.equal(step(chapterRef('PSA', 23), 1), 'PSA.24');
  assert.equal(step(verseRef('GEN', 1, 1), -1), null);
  assert.equal(step(verseRef('REV', 22, 21), 1), null);
});
