import test from 'node:test';
import assert from 'node:assert/strict';
import { arrangementOf, creditLine, lyricsScreen, matchesSearch, parseOpenLyrics, parsePlainTextSong, sectionStops, songToPlainText, validateSong } from '../../shared/lyrics/songs.js';
import { SAMPLE_SONGS } from '../../shared/lyrics/sampleSongs.js';

const [lantern] = SAMPLE_SONGS;

test('plain text: labelled sections, with a bare label as a repeat', () => {
  const song = parsePlainTextSong(`[Verse 1]\nLine one\nLine two\n\n[Chorus]\nSing it\n\nVerse 2:\nLine three\n\n[Chorus]\n`);
  assert.deepEqual(song.sections.map((s) => [s.id, s.label, s.lines.length]), [['v1', 'Verse 1', 2], ['c', 'Chorus', 1], ['v2', 'Verse 2', 1]]);
  assert.deepEqual(song.order, ['v1', 'c', 'v2', 'c']);
});

test('plain text: headers and an explicit order', () => {
  const song = parsePlainTextSong(`Title: Sample\nArtist: Someone\nCCLI: 123\nOrder: V1 C C\n\n[V1]\nA line\n[C]\nB line`);
  assert.equal(song.title, 'Sample');
  assert.equal(song.artist, 'Someone');
  assert.equal(song.ccli, '123');
  assert.deepEqual(song.order, ['v1', 'c', 'c']);
});

test('plain text: unlabelled blocks become verses', () => {
  const song = parsePlainTextSong('First line\nSecond line\n\nThird line');
  assert.deepEqual(song.sections.map((s) => s.label), ['Verse 1', 'Verse 2']);
  assert.deepEqual(song.order, ['v1', 'v2']);
});

test('plain text: a lyric that looks like a letter is not a label', () => {
  const song = parsePlainTextSong('[Verse 1]\nC\nA real line');
  assert.deepEqual(song.sections[0].lines, ['C', 'A real line']);
});

test('plain text: a retyped section keeps one copy and repeats in the order', () => {
  const song = parsePlainTextSong('[Chorus]\nSame words\n\n[Verse 1]\nOther\n\n[Chorus]\nSame words');
  assert.equal(song.sections.length, 2);
  assert.deepEqual(song.order, ['c', 'v1', 'c']);
});

test('windows line endings', () => {
  assert.deepEqual(parsePlainTextSong('[Chorus]\r\nOne\r\nTwo\r\n').sections[0].lines, ['One', 'Two']);
});

test('round trip through plain text', () => {
  const parsed = parsePlainTextSong(songToPlainText(lantern));
  assert.equal(parsed.title, lantern.title);
  assert.deepEqual(parsed.order, lantern.order);
  assert.deepEqual(parsed.sections.map((s) => s.lines), lantern.sections.map((s) => s.lines));
});

test('OpenLyrics import', () => {
  const song = parseOpenLyrics(`<?xml version="1.0"?>
<song xmlns="http://openlyrics.info/namespace/2009/song" version="0.9">
  <properties>
    <titles><title lang="en">Fake &amp; Sample</title></titles>
    <authors><author>A Writer</author><author type="words">B Writer</author></authors>
    <ccliNo>4242</ccliNo>
    <verseOrder>v1 c1 v1</verseOrder>
  </properties>
  <lyrics>
    <verse name="v1"><lines>First line<br/>Second <chord name="G"/>line</lines></verse>
    <verse name="c1"><lines><comment>softly</comment>Chorus line</lines></verse>
  </lyrics>
</song>`);
  assert.equal(song.title, 'Fake & Sample');
  assert.equal(song.artist, 'A Writer, B Writer');
  assert.equal(song.ccli, '4242');
  assert.deepEqual(song.order, ['v1', 'c1', 'v1']);
  assert.deepEqual(song.sections[0].lines, ['First line', 'Second line']);
  assert.deepEqual(song.sections[1].lines, ['Chorus line']);
  assert.equal(song.sections[1].label, 'Chorus 1');
  assert.deepEqual(validateSong(song), []);
});

test('OpenLyrics: other XML is refused', () => {
  assert.throws(() => parseOpenLyrics('<html></html>'), /OpenLyrics/);
});

test('validation', () => {
  assert.match(validateSong({ title: '', sections: [{ id: 'v1', lines: ['x'] }] })[0], /title/);
  assert.match(validateSong({ title: 'x', sections: [] })[0], /section/);
  assert.match(validateSong({ title: 'x', order: ['z'], sections: [{ id: 'v1', lines: ['x'] }] })[0], /“z”/);
  for (const song of SAMPLE_SONGS) assert.deepEqual(validateSong(song), [], song.title);
});

test('the arrangement repeats sections in order', () => {
  const lines = arrangementOf(lantern);
  assert.equal(lines.length, 4 + 4 + 4 + 4 + 2 + 4);
  assert.equal(lines[4].sectionId, 'c');
  assert.equal(lines[12].sectionId, 'c');
  assert.equal(lines[12].orderIndex, 3);
  assert.deepEqual(sectionStops(lines).map((s) => s.label), ['Verse 1', 'Chorus', 'Verse 2', 'Chorus', 'Bridge', 'Chorus']);
});

test('the credit line', () => {
  const song = { title: 'T', artist: 'A', ccli: '99' };
  assert.equal(creditLine(song, { ccliLicense: '123' }), 'T — A · CCLI Song # 99 · CCLI License # 123');
  assert.equal(creditLine({ title: 'T' }), 'T');
  assert.equal(creditLine(song, { showCredit: false }), '');
});

test('the lyric screen shows one or two lines', () => {
  const lines = arrangementOf(lantern);
  const two = lyricsScreen(lantern, lines, 0, {});
  assert.deepEqual(two.lines.map((l) => l.current), [true, false]);
  assert.equal(lyricsScreen(lantern, lines, 0, { linesPerScreen: 1 }).lines.length, 1);
  assert.equal(lyricsScreen(lantern, lines, lines.length - 1, {}).lines.length, 1);
});

test('search covers titles, artists and lyrics', () => {
  assert.ok(matchesSearch(lantern, 'lantern'));
  assert.ok(matchesSearch(lantern, 'copper bell'));
  assert.ok(matchesSearch(lantern, 'demo'));
  assert.ok(!matchesSearch(lantern, 'nonsense word'));
  assert.ok(matchesSearch(lantern, ''));
});

test('sample songs are labelled as samples', () => {
  for (const song of SAMPLE_SONGS) {
    assert.match(song.title, /^\[Sample\]/);
    assert.equal(song.sample, true);
  }
});
