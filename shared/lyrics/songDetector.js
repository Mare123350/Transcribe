// Works out which song is being sung from a rolling window of cleaned transcript words. Evidence
// builds over several updates, and only distinct lines add to it, so vamping on one line or a line
// shared between songs can't produce a confident match.
import { SongIndex } from './songIndex.js';

export class SongDetector {
  constructor({ thresholds, now = () => Date.now() }) {
    this.t = thresholds;
    this.now = now;
    this.window = [];
    this.scopes = [];
    this.rejected = new Set();
  }

  // The setlist is searched first, and the full library only if nothing in the setlist matches.
  setSongs({ setlist = [], library = [] }) {
    this.scopes = [];
    if (setlist.length) this.scopes.push({ name: 'setlist', index: new SongIndex(setlist), candidates: new Map() });
    if (library.length) this.scopes.push({ name: 'library', index: new SongIndex(library), candidates: new Map() });
  }

  reset() {
    this.window = [];
    for (const scope of this.scopes) scope.candidates = new Map();
  }

  // Forgets accumulated evidence for one song, such as after it has ended.
  forget(songId) {
    for (const scope of this.scopes) scope.candidates.delete(songId);
  }

  reject(songId) {
    this.rejected.add(songId);
    this.forget(songId);
  }

  allow(songId) {
    this.rejected.delete(songId);
  }

  containsPhrase(words) {
    return this.scopes.some((scope) => scope.index.containsPhrase(words));
  }

  // Adds new words. Returns { candidates, lyricShare } where lyricShare is how much of this update
  // was recognizably from a song.
  update(words) {
    const at = this.now();
    const fresh = words.map((word) => ({ word, at, lyric: false }));
    this.window.push(...fresh);
    this.window = this.window.filter((item) => at - item.at <= this.t.windowMs);
    const heard = this.window.map((item) => item.word);

    let chosen = [];
    for (const scope of this.scopes) {
      const hits = scope.index.query(heard, this.t);
      for (const hit of hits) {
        for (let i = hit.start; i <= hit.end; i++) this.window[i].lyric = true;
      }
      this.absorb(scope, hits, at);
      const ranked = this.rank(scope, at);
      if (!chosen.length && ranked.length) chosen = ranked;
    }
    const lyricWords = fresh.filter((item) => item.lyric).length;
    return { candidates: chosen, lyricShare: fresh.length ? lyricWords / fresh.length : 0, fresh };
  }

  absorb(scope, hits, at) {
    const hitSongs = new Set();
    for (const hit of hits) {
      if (this.rejected.has(hit.songId)) continue;
      hitSongs.add(hit.songId);
      if (!scope.candidates.has(hit.songId)) scope.candidates.set(hit.songId, { songId: hit.songId, lines: new Map(), consecutive: 0 });
      const candidate = scope.candidates.get(hit.songId);
      const lengthFactor = Math.min(1, hit.line.words.length / 5);
      const score = Math.min(1, hit.coverage) * lengthFactor;
      const existing = candidate.lines.get(hit.line.key);
      candidate.lines.set(hit.line.key, { score: Math.max(score, existing?.score ?? 0), uniqueness: hit.line.uniqueness, at, end: hit.end });
      candidate.lastLineKey = [...candidate.lines.entries()].sort((a, b) => a[1].end - b[1].end).at(-1)[0];
    }
    for (const [songId, candidate] of scope.candidates) {
      candidate.consecutive = hitSongs.has(songId) ? candidate.consecutive + 1 : 0;
      for (const [key, line] of candidate.lines) {
        if (at - line.at > this.t.memoryMs) candidate.lines.delete(key);
      }
      if (!candidate.lines.size) scope.candidates.delete(songId);
    }
  }

  rank(scope) {
    const scored = [...scope.candidates.values()].map((candidate) => {
      const evidence = [...candidate.lines.values()].reduce((sum, line) => sum + line.score * line.uniqueness, 0);
      const distinctLines = [...candidate.lines.values()].filter((line) => line.uniqueness > 0.5).length;
      return { candidate, raw: 1 - Math.exp(-evidence / this.t.scoreScale), distinctLines };
    }).sort((a, b) => b.raw - a.raw);

    const top = scored[0]?.raw ?? 0;
    const second = scored[1]?.raw ?? 0;
    return scored
      .filter((item) => item.raw >= this.t.suggestThreshold)
      .slice(0, 3)
      .map((item, position) => {
        const rival = position === 0 ? second : top;
        // A close rival hurts a lot, and a distant one hardly at all.
        const closeness = Math.min(1, rival / item.raw);
        const confidence = item.raw * (1 - this.t.marginPenalty * closeness * closeness);
        return {
          songId: item.candidate.songId,
          scope: scope.name,
          confidence,
          raw: item.raw,
          distinctLines: item.distinctLines,
          consecutive: item.candidate.consecutive,
          lastLineKey: item.candidate.lastLineKey,
          eligible: confidence >= this.t.autoThreshold
            && item.distinctLines >= this.t.minDistinctLines
            && item.candidate.consecutive >= this.t.minConsecutiveWindows,
        };
      });
  }

  songById(songId) {
    for (const scope of this.scopes) {
      const song = scope.index.songs.get(songId);
      if (song) return song;
    }
    return null;
  }
}
