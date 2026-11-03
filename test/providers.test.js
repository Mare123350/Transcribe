import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createBibleRegistry } from '../server/bible/registry.js';
import { PassageCache, parseMarkedVerses } from '../server/bible/remoteHelpers.js';
import { chapterRef, verseRef } from '../shared/references.js';
import { CANONICAL_VERSIFICATION } from '../shared/versification.js';

const dataDir = new URL('../data', import.meta.url).pathname;
const local = await createBibleRegistry({ env: {}, dataDir });

function respond(status, body) {
  return { status, ok: status >= 200 && status < 300, json: async () => body };
}

test('bundled data is complete', () => {
  for (const file of ['kjv.json', 'web.json']) {
    const { books } = JSON.parse(readFileSync(`${dataDir}/${file}`, 'utf8'));
    assert.equal(Object.keys(books).length, 66, file);
    assert.equal(Object.values(books).flat().length, 1189, file);
  }
  const verses = Object.values(CANONICAL_VERSIFICATION).flat().reduce((a, b) => a + b, 0);
  assert.equal(verses, 31102);
});

test('local lookup returns the actual text with its translation named', async () => {
  const passage = await local.getPassage(verseRef('JHN', 3, 16), 'kjv');
  assert.equal(passage.reference, 'John 3:16');
  assert.equal(passage.translation.abbreviation, 'KJV');
  assert.match(passage.verses[0].text, /^For God so loved the world/);
  const web = await local.getPassage(verseRef('JHN', 3, 16), 'web');
  assert.equal(web.translation.abbreviation, 'WEB');
  assert.match(web.verses[0].text, /one and only Son/);
});

test('ranges and whole chapters', async () => {
  const range = await local.getPassage(verseRef('1CO', 13, 4, 7), 'kjv');
  assert.deepEqual(range.verses.map((v) => v.verse), [4, 5, 6, 7]);
  const chapter = await local.getPassage(chapterRef('PSA', 23), 'kjv');
  assert.equal(chapter.verses.length, 6);
  assert.equal(chapter.reference, 'Psalm 23');
  assert.match(chapter.verses[0].text, /^The LORD is my shepherd/);
});

test('references that do not exist are not_found', async () => {
  await assert.rejects(local.getPassage(chapterRef('JHN', 35), 'kjv'), { code: 'not_found' });
  await assert.rejects(local.getPassage(verseRef('JHN', 3, 99), 'kjv'), { code: 'not_found' });
  await assert.rejects(local.getPassage(verseRef('ROM', 16, 27), 'web'), { code: 'not_found' });
});

test('a verse a translation omits is reported, not invented', async () => {
  await assert.rejects(local.getPassage(verseRef('ACT', 8, 37), 'web'), { code: 'not_found' });
  const range = await local.getPassage(verseRef('ACT', 8, 36, 38), 'web');
  assert.deepEqual(range.verses.map((v) => v.verse), [36, 38]);
  assert.deepEqual(range.omitted, [37]);
  assert.match((await local.getPassage(verseRef('ACT', 8, 37), 'kjv')).verses[0].text, /Philip said/);
});

test('versification is specific to each translation', () => {
  assert.equal(local.versification('kjv').books.ROM[15], 27);
  assert.equal(local.versification('web').books.ROM[15], 24);
  assert.equal(local.versification('kjv').exact, true);
});

test('unconfigured translations are listed as unavailable and never substituted', async () => {
  const niv = local.listing().find((t) => t.id === 'niv');
  assert.equal(niv.available, false);
  assert.match(niv.unavailableReason, /API_BIBLE_KEY/);
  await assert.rejects(local.getPassage(verseRef('JHN', 3, 16), 'niv'), { code: 'unavailable' });
  await assert.rejects(local.getPassage(verseRef('JHN', 3, 16), 'nope'), { code: 'unavailable' });
  for (const id of ['kjv', 'nkjv', 'niv', 'esv', 'nlt', 'nasb', 'nrsv']) {
    assert.ok(local.listing().some((t) => t.id === id), id);
  }
});

const apiBibleEnv = { API_BIBLE_KEY: 'secret-key', API_BIBLE_ID_NIV: 'bible123' };

test('API.Bible: request shape and parsed response', async () => {
  const calls = [];
  const registry = await createBibleRegistry({
    env: apiBibleEnv,
    dataDir,
    fetchImpl: async (url, options) => {
      calls.push({ url, options });
      return respond(200, { data: { content: '     [16] First verse text.  [17] Second verse text. ', copyright: 'Licensed copyright' } });
    },
  });
  const passage = await registry.getPassage(verseRef('JHN', 3, 16, 17), 'niv');
  assert.match(calls[0].url, /^https:\/\/rest\.api\.bible\/v1\/bibles\/bible123\/passages\/JHN\.3\.16-JHN\.3\.17\?/);
  assert.match(calls[0].url, /content-type=text/);
  assert.equal(calls[0].options.headers['api-key'], 'secret-key');
  assert.deepEqual(passage.verses, [{ verse: 16, text: 'First verse text.' }, { verse: 17, text: 'Second verse text.' }]);
  assert.equal(passage.copyright, 'Licensed copyright');
  assert.equal(passage.translation.abbreviation, 'NIV');

  await registry.getPassage(verseRef('JHN', 3, 16, 17), 'niv');
  assert.equal(calls.length, 1, 'second lookup comes from the cache');
  await registry.getPassage(chapterRef('JHN', 3), 'niv');
  assert.match(calls[1].url, /passages\/JHN\.3\?/);
  await registry.getPassage(verseRef('JHN', 3, 16), 'niv');
  assert.match(calls[2].url, /passages\/JHN\.3\.16\?/);
});

test('API translations accept verses past the KJV table and let the provider decide', async () => {
  const registry = await createBibleRegistry({
    env: apiBibleEnv,
    dataDir,
    fetchImpl: async () => respond(200, { data: { content: '[15] Peace be to you.' } }),
  });
  const passage = await registry.getPassage(verseRef('3JN', 1, 15), 'niv');
  assert.equal(passage.verses[0].verse, 15);
  await assert.rejects(registry.getPassage(chapterRef('JHN', 99), 'niv'), { code: 'not_found' });
});

test('provider failures become clear errors and never fall back to other text', async () => {
  const failing = (fetchImpl) => createBibleRegistry({ env: { ...apiBibleEnv, ESV_API_KEY: 'k' }, dataDir, fetchImpl });
  const ref = verseRef('JHN', 3, 16);
  await assert.rejects((await failing(async () => respond(404, {}))).getPassage(ref, 'niv'), { code: 'not_found' });
  await assert.rejects((await failing(async () => respond(401, {}))).getPassage(ref, 'niv'), { code: 'unavailable' });
  await assert.rejects((await failing(async () => respond(403, {}))).getPassage(ref, 'esv'), { code: 'unavailable' });
  await assert.rejects((await failing(async () => respond(429, {}))).getPassage(ref, 'niv'), { code: 'upstream' });
  await assert.rejects((await failing(async () => respond(500, {}))).getPassage(ref, 'esv'), { code: 'upstream' });
  await assert.rejects((await failing(async () => { throw new Error('offline'); })).getPassage(ref, 'niv'), { code: 'upstream' });
  await assert.rejects((await failing(async () => respond(200, { data: { content: '   ' } }))).getPassage(ref, 'niv'), { code: 'not_found' });
});

test('ESV: request shape and parsed response', async () => {
  const calls = [];
  const registry = await createBibleRegistry({
    env: { ESV_API_KEY: 'esv-secret' },
    dataDir,
    fetchImpl: async (url, options) => {
      calls.push({ url, options });
      return respond(200, { passages: ['[16] For God so loved.\n\n[17] For God did not.'] });
    },
  });
  const passage = await registry.getPassage(verseRef('1CO', 13, 4, 7), 'esv');
  const url = new URL(calls[0].url);
  assert.equal(url.origin + url.pathname, 'https://api.esv.org/v3/passage/text/');
  assert.equal(url.searchParams.get('q'), '1 Corinthians 13:4-7');
  assert.equal(url.searchParams.get('include-headings'), 'false');
  assert.equal(calls[0].options.headers.Authorization, 'Token esv-secret');
  assert.equal(passage.verses.length, 2);
  assert.match(passage.copyright, /Crossway/);
});

test('ESV: an empty answer is not_found', async () => {
  const registry = await createBibleRegistry({ env: { ESV_API_KEY: 'k' }, dataDir, fetchImpl: async () => respond(200, { passages: [] }) });
  await assert.rejects(registry.getPassage(verseRef('JHN', 3, 16), 'esv'), { code: 'not_found' });
});

test('marked text parsing', () => {
  assert.deepEqual(parseMarkedVerses('no markers here', 5), [{ verse: 5, text: 'no markers here' }]);
  assert.deepEqual(parseMarkedVerses('', 5), []);
});

test('the passage cache stays inside its verse limit', () => {
  const cache = new PassageCache(10);
  const passage = (n) => ({ verses: Array(n).fill({}) });
  cache.set('a', passage(6));
  cache.set('b', passage(6));
  assert.equal(cache.get('a'), undefined);
  assert.ok(cache.get('b'));
  assert.equal(cache.total, 6);
  cache.set('huge', passage(11));
  assert.equal(cache.get('huge'), undefined);
});
