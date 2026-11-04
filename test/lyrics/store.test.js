import test, { after, before } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, readdir, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createApp } from '../../server/app.js';
import { createLyricsStore } from '../../server/lyrics/store.js';

let directory;
let app;
let base;
const song = { title: 'Fake Song', artist: 'Nobody', sections: [{ id: 'v1', type: 'verse', label: 'Verse 1', lines: ['Line one', '  Line two  ', ''] }] };
const json = (method, body) => ({ method, headers: { 'content-type': 'application/json' }, body: JSON.stringify(body) });

before(async () => {
  directory = await mkdtemp(join(tmpdir(), 'transcribe-lyrics-'));
  app = await createApp({ env: {}, lyricsDir: directory });
  await new Promise((resolve) => app.server.listen(0, '127.0.0.1', resolve));
  base = `http://127.0.0.1:${app.server.address().port}/api`;
});

after(async () => {
  app.server.closeAllConnections();
  await new Promise((resolve) => app.server.close(resolve));
  await rm(directory, { recursive: true, force: true });
});

test('songs: create, list, update, delete over the API', async () => {
  const created = await (await fetch(`${base}/songs`, json('POST', song))).json();
  assert.ok(created.id);
  assert.deepEqual(created.sections[0].lines, ['Line one', 'Line two']);
  assert.deepEqual(created.order, ['v1']);

  assert.equal((await (await fetch(`${base}/songs`)).json()).length, 1);

  const updated = await (await fetch(`${base}/songs/${created.id}`, json('PUT', { ...song, title: 'Renamed' }))).json();
  assert.equal(updated.title, 'Renamed');
  assert.equal(updated.id, created.id);

  assert.equal((await fetch(`${base}/songs/${created.id}`, { method: 'DELETE' })).status, 204);
  assert.equal((await fetch(`${base}/songs/${created.id}`, { method: 'DELETE' })).status, 404);
});

test('songs: invalid ones are refused with a reason', async () => {
  const response = await fetch(`${base}/songs`, json('POST', { title: '', sections: [] }));
  assert.equal(response.status, 400);
  assert.match((await response.json()).error.message, /title/);
});

test('settings: defaults, updates, and unknown keys ignored', async () => {
  const defaults = await (await fetch(`${base}/lyrics-settings`)).json();
  assert.equal(defaults.linesPerScreen, 2);
  const updated = await (await fetch(`${base}/lyrics-settings`, json('PUT', { ccliLicense: '555', nonsense: true }))).json();
  assert.equal(updated.ccliLicense, '555');
  assert.equal(updated.nonsense, undefined);
});

test('the library survives a restart, and earlier versions are backed up', async () => {
  const folder = await mkdtemp(join(tmpdir(), 'transcribe-lyrics-'));
  const store = createLyricsStore(folder);
  const first = await store.createSong(song);
  await store.updateSong(first.id, { ...song, title: 'Second version' });

  const reopened = createLyricsStore(folder);
  assert.equal((await reopened.listSongs())[0].title, 'Second version');

  const backups = await readdir(join(folder, 'backups'));
  assert.equal(backups.length, 1);
  assert.match(await readFile(join(folder, 'backups', backups[0]), 'utf8'), /Fake Song/);
  await rm(folder, { recursive: true, force: true });
});

test('quick writes in a row do not lose songs', async () => {
  const folder = await mkdtemp(join(tmpdir(), 'transcribe-lyrics-'));
  const store = createLyricsStore(folder);
  await Promise.all(Array.from({ length: 12 }, (_, i) => store.createSong({ ...song, title: `Song ${i}` })));
  assert.equal((await createLyricsStore(folder).listSongs()).length, 12);
  await rm(folder, { recursive: true, force: true });
});

test('a damaged library file is reported rather than silently replaced', async () => {
  const { writeFile } = await import('node:fs/promises');
  const folder = await mkdtemp(join(tmpdir(), 'transcribe-lyrics-'));
  await writeFile(join(folder, 'lyrics.json'), '{ not json');
  await assert.rejects(createLyricsStore(folder).listSongs(), /Couldn't read/);
  assert.equal(await readFile(join(folder, 'lyrics.json'), 'utf8'), '{ not json');
  await rm(folder, { recursive: true, force: true });
});

test('setlists: ordering, unknown songs dropped, and deleting a song removes it from setlists', async () => {
  const folder = await mkdtemp(join(tmpdir(), 'transcribe-lyrics-'));
  const store = createLyricsStore(folder);
  const a = await store.createSong({ ...song, title: 'A' });
  const b = await store.createSong({ ...song, title: 'B' });
  const setlist = await store.createSetlist({ name: 'Sunday', date: '2026-11-08', songIds: [b.id, 'missing', a.id] });
  assert.deepEqual(setlist.songIds, [b.id, a.id]);

  await assert.rejects(store.createSetlist({ name: '  ' }), /name/);

  await store.updateSettings({ activeSetlistId: setlist.id });
  await store.deleteSong(b.id);
  assert.deepEqual((await store.listSetlists())[0].songIds, [a.id]);
  await store.deleteSetlist(setlist.id);
  assert.equal((await store.getSettings()).activeSetlistId, null, 'the active setlist is cleared with it');
  await rm(folder, { recursive: true, force: true });
});

test('setlists over the API', async () => {
  const created = await (await fetch(`${base}/setlists`, json('POST', { name: 'Evening', date: '2026-11-08', songIds: [] }))).json();
  assert.ok(created.id);
  const updated = await (await fetch(`${base}/setlists/${created.id}`, json('PUT', { name: 'Renamed' }))).json();
  assert.equal(updated.name, 'Renamed');
  assert.equal((await fetch(`${base}/setlists/${created.id}`, { method: 'DELETE' })).status, 204);
  assert.equal((await fetch(`${base}/setlists/${created.id}`, json('PUT', { name: 'x' }))).status, 404);
});
