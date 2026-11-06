// A searchable index of song lines. Rare words count for more than common ones, and each line knows
// how many songs share it, so a line found in several songs carries little weight.
import { arrangementOf } from './songs.js';
import { alignLine, normalizeWords, phoneticKey } from './text.js';

const MAX_LINES_TO_ALIGN = 200;

export class SongIndex {
  constructor(songs) {
    this.songs = new Map(songs.map((song) => [song.id, song]));
    this.lines = [];
    this.postings = new Map();
    const seen = new Set();
    const documentFrequency = new Map();

    for (const song of songs) {
      for (const { text } of arrangementOf(song)) {
        const words = normalizeWords(text);
        const key = words.join(' ');
        const id = `${song.id}\n${key}`;
        if (!words.length || seen.has(id)) continue;
        seen.add(id);
        const keys = new Set(words.map(phoneticKey));
        this.lines.push({ songId: song.id, key, words, keys });
        for (const k of keys) documentFrequency.set(k, (documentFrequency.get(k) ?? 0) + 1);
      }
    }

    const total = this.lines.length || 1;
    this.lines.forEach((line, lineIndex) => {
      line.weighted = line.words.map((word) => ({ word, weight: Math.log(1 + total / documentFrequency.get(phoneticKey(word))) }));
      for (const k of line.keys) {
        if (!this.postings.has(k)) this.postings.set(k, []);
        this.postings.get(k).push(lineIndex);
      }
    });

    // How many different songs contain this line, allowing for small wording differences.
    for (const line of this.lines) {
      const sharing = new Set([line.songId]);
      const counts = new Map();
      for (const k of line.keys) for (const other of this.postings.get(k)) counts.set(other, (counts.get(other) ?? 0) + 1);
      for (const [other, overlap] of counts) {
        const peer = this.lines[other];
        if (peer.songId === line.songId) continue;
        if (overlap / (line.keys.size + peer.keys.size - overlap) >= 0.8) sharing.add(peer.songId);
      }
      line.uniqueness = 1 / sharing.size;
    }
  }

  // Every song line heard in `words`.
  query(words, { minLineCoverage = 0.6, minLineWords = 3 } = {}) {
    const counts = new Map();
    for (const k of new Set(words.map(phoneticKey))) {
      for (const lineIndex of this.postings.get(k) ?? []) counts.set(lineIndex, (counts.get(lineIndex) ?? 0) + 1);
    }
    const candidates = [...counts.entries()]
      .filter(([lineIndex, count]) => count >= Math.min(2, this.lines[lineIndex].keys.size))
      .sort((a, b) => b[1] - a[1])
      .slice(0, MAX_LINES_TO_ALIGN);

    const hits = [];
    for (const [lineIndex] of candidates) {
      const line = this.lines[lineIndex];
      const match = alignLine(line.weighted, words);
      if (match.coverage < minLineCoverage || match.words < Math.min(minLineWords, line.words.length)) continue;
      hits.push({ line, songId: line.songId, coverage: match.coverage, words: match.words, start: match.start, end: match.end });
    }
    return hits;
  }

  // Whether a phrase appears inside any song line, e.g. "john three sixteen" in a lyric.
  containsPhrase(words) {
    if (!words.length) return false;
    const target = words.map((word) => ({ word, weight: 1 }));
    return this.lines.some((line) => alignLine(target, line.words).coverage >= 0.8);
  }
}
