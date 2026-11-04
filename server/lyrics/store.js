import { randomUUID } from 'node:crypto';
import { copyFile, mkdir, readdir, readFile, rename, rm, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { validateSong } from '../../shared/lyrics/songs.js';

const EMPTY = () => ({ version: 1, songs: [], setlists: [], settings: {} });
const MAX_BACKUPS = 20;

export const DEFAULT_SETTINGS = {
  ccliLicense: '',
  showCredit: true,
  highlightCurrent: true,
  linesPerScreen: 2,
  activeSetlistId: null,
  thresholds: {},
};

export class ValidationError extends Error {}
export class NotFoundError extends Error {}

// The church's lyrics, in one JSON file on the operator computer. Each write replaces the file in a
// single step, and the previous version is kept in backups/, so a crash can't corrupt the library.
export function createLyricsStore(directory) {
  const file = join(directory, 'lyrics.json');
  const backups = join(directory, 'backups');
  let data = null;
  let queue = Promise.resolve();

  async function load() {
    if (data) return data;
    try {
      data = { ...EMPTY(), ...JSON.parse(await readFile(file, 'utf8')) };
    } catch (error) {
      if (error.code !== 'ENOENT') throw new Error(`Couldn't read ${file}: ${error.message}`);
      data = EMPTY();
    }
    return data;
  }

  async function save() {
    await mkdir(backups, { recursive: true });
    try {
      await copyFile(file, join(backups, `lyrics-${new Date().toISOString().replace(/[:.]/g, '-')}.json`));
      const old = (await readdir(backups)).sort();
      await Promise.all(old.slice(0, Math.max(0, old.length - MAX_BACKUPS)).map((name) => rm(join(backups, name))));
    } catch (error) {
      if (error.code !== 'ENOENT') throw error;
    }
    const temporary = `${file}.tmp`;
    await writeFile(temporary, JSON.stringify(data, null, 2));
    await rename(temporary, file);
  }

  // Writes run one at a time, so two quick edits can't overwrite each other.
  const change = (mutate) => {
    const run = queue.then(async () => {
      await load();
      const result = mutate(data);
      await save();
      return result;
    });
    queue = run.catch(() => {});
    return run;
  };

  const cleanSong = (input, id) => {
    const problems = validateSong(input);
    if (problems.length) throw new ValidationError(problems.join(' '));
    return {
      id,
      title: String(input.title).trim(),
      artist: String(input.artist ?? '').trim(),
      language: String(input.language ?? 'en').trim() || 'en',
      ccli: String(input.ccli ?? '').trim(),
      order: input.order?.length ? input.order.map(String) : input.sections.map((s) => s.id),
      sections: input.sections.map((s) => ({
        id: String(s.id),
        type: String(s.type ?? 'verse'),
        label: String(s.label ?? s.id),
        lines: (s.lines ?? []).map((line) => String(line).trim()).filter(Boolean),
      })),
    };
  };

  return {
    directory,
    async listSongs() {
      return [...(await load()).songs].sort((a, b) => a.title.localeCompare(b.title));
    },
    createSong: (input) => change((d) => {
      const song = cleanSong(input, randomUUID());
      d.songs.push(song);
      return song;
    }),
    updateSong: (id, input) => change((d) => {
      const index = d.songs.findIndex((s) => s.id === id);
      if (index < 0) throw new NotFoundError('That song no longer exists.');
      d.songs[index] = cleanSong(input, id);
      return d.songs[index];
    }),
    deleteSong: (id) => change((d) => {
      const before = d.songs.length;
      d.songs = d.songs.filter((s) => s.id !== id);
      if (d.songs.length === before) throw new NotFoundError('That song no longer exists.');
      for (const setlist of d.setlists) setlist.songIds = setlist.songIds.filter((songId) => songId !== id);
    }),

    async getSettings() {
      return { ...DEFAULT_SETTINGS, ...(await load()).settings };
    },
    updateSettings: (patch) => change((d) => {
      const allowed = Object.fromEntries(Object.entries(patch ?? {}).filter(([key]) => key in DEFAULT_SETTINGS));
      d.settings = { ...d.settings, ...allowed };
      return { ...DEFAULT_SETTINGS, ...d.settings };
    }),

    async exportAll() {
      return load();
    },
  };
}
