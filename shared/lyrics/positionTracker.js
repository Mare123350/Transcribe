// Follows where a locked song is up to. Moving to the next line, or repeating the current one, needs
// little evidence, and so does reaching a line just ahead. Moving anywhere else needs more, because repeated text is everywhere in worship
// songs and the same words can belong to several places.
import { arrangementOf } from './songs.js';
import { alignLine, normalizeWords, phoneticKey } from './text.js';

export class PositionTracker {
  constructor(song, { thresholds, startIndex = 0 }) {
    this.t = thresholds;
    this.lines = arrangementOf(song);

    // Weight rare words within this song, so a shared opening like "hold the" doesn't decide a match.
    const counts = new Map();
    const parsed = this.lines.map((line) => normalizeWords(line.text));
    for (const words of new Set(parsed.map((w) => w.join(' ')))) {
      for (const k of new Set(words.split(' ').map(phoneticKey))) counts.set(k, (counts.get(k) ?? 0) + 1);
    }
    const distinct = new Set(parsed.map((w) => w.join(' '))).size || 1;
    this.lines = this.lines.map((line, i) => ({
      ...line,
      key: parsed[i].join(' '),
      weighted: parsed[i].map((word) => ({ word, weight: Math.log(1 + distinct / (counts.get(phoneticKey(word)) ?? 1)) })),
    }));

    // Lines with the same words, grouped, with how many different sections hold them.
    this.groups = new Map();
    for (const line of this.lines) {
      if (!line.key) continue;
      if (!this.groups.has(line.key)) this.groups.set(line.key, { key: line.key, weighted: line.weighted, indexes: [], sections: new Set() });
      const group = this.groups.get(line.key);
      group.indexes.push(line.index);
      group.sections.add(line.sectionId);
    }

    this.index = Math.max(0, Math.min(startIndex, this.lines.length - 1));
    this.tail = [];
    this.pending = null;
    this.repeats = 0;
    this.lastMatchAt = null;
  }

  nextIndex(from = this.index) {
    let index = from + 1;
    while (index < this.lines.length && !this.lines[index].key) index++; // lines that are only "oh oh oh"
    return index < this.lines.length ? index : null;
  }

  // Which copy of repeated words to move to: the same section again (a chorus being repeated), else
  // the nearest one ahead, else the first.
  nearestCopy(indexes) {
    const currentOrder = this.lines[this.index].orderIndex;
    return indexes.find((i) => this.lines[i].orderIndex === currentOrder)
      ?? indexes.find((i) => i > this.index)
      ?? indexes[0];
  }

  matchInTail(line) {
    return alignLine(line.weighted, this.tail.map((item) => item.word));
  }

  // Adds new words and returns the position if it changed, or null.
  update(words, at) {
    this.tail.push(...words.map((word) => ({ word, at })));
    this.tail = this.tail.filter((item) => at - item.at <= this.t.tailMs);
    if (this.pending && at - this.pending.at > this.t.jumpConfirmMs) this.pending = null;

    const startedAt = this.index;
    for (let moves = 0; moves < 8; moves++) {
      const move = this.bestMove(at);
      if (!move) break;
      this.tail = this.tail.slice(move.end + 1);
      this.lastMatchAt = at;
      if (move.kind === 'stay') this.repeats++;
      else if (move.kind !== 'wait') {
        this.index = move.index;
        this.repeats = 0;
      }
    }
    return this.index !== startedAt ? this.index : null;
  }

  bestMove(at) {
    if (!this.tail.length) return null;
    const options = [];
    const next = this.nextIndex();
    const current = this.lines[this.index];
    const minWords = (line) => Math.min(this.t.minLineWords, line.weighted.length);

    if (next != null) {
      const match = this.matchInTail(this.lines[next]);
      if (match.coverage >= this.t.advanceCoverage && match.words >= minWords(this.lines[next])) {
        options.push({ kind: 'next', index: next, end: match.end, rank: 0 });
      }
    }
    // A line or two ahead: the one in between probably went unheard. Being this close is itself the
    // supporting context, so this doesn't need the proof a longer jump does.
    let ahead = next;
    const skipped = new Set([current.key, this.lines[next ?? -1]?.key]);
    for (let step = 0; step < this.t.skipAheadLines && ahead != null; step++) {
      ahead = this.nextIndex(ahead);
      if (ahead == null) break;
      const line = this.lines[ahead];
      if (skipped.has(line.key)) continue;
      skipped.add(line.key);
      const match = this.matchInTail(line);
      if (match.coverage >= this.t.skipCoverage && match.words >= minWords(line)) {
        options.push({ kind: 'next', index: ahead, end: match.end, rank: 0.5 });
      }
    }
    if (current.key) {
      const match = this.matchInTail(current);
      if (match.coverage >= this.t.stayCoverage && match.words >= minWords(current)) {
        options.push({ kind: 'stay', end: match.end, rank: 1 });
      }
    }
    for (const group of this.groups.values()) {
      if (skipped.has(group.key)) continue;
      const match = alignLine(group.weighted, this.tail.map((item) => item.word));
      if (match.coverage < this.t.jumpCoverage || match.words < Math.min(this.t.minLineWords, group.weighted.length)) continue;
      options.push({ ...this.jumpOption(group, match, at), end: match.end, rank: 2 });
    }
    if (!options.length) return null;
    options.sort((a, b) => a.end - b.end || a.rank - b.rank);
    return options[0];
  }

  // A jump needs support: either a very clear hit on a line found in one section only, or two
  // lines in a row that agree. Until then the position stays where it is.
  jumpOption(group, match, at) {
    const strong = match.coverage >= this.t.strongJumpCoverage
      && match.words >= this.t.strongJumpWords
      && group.sections.size === 1;

    if (this.pending) {
      const supported = group.indexes.filter((index) => this.pending.indexes.some((earlier) => earlier === index || this.nextIndex(earlier) === index));
      if (supported.length) {
        this.pending = null;
        return { kind: 'jump', index: this.nearestCopy(supported) };
      }
    }
    if (strong) {
      this.pending = null;
      return { kind: 'jump', index: this.nearestCopy(group.indexes) };
    }
    this.pending = { indexes: group.indexes, at };
    return { kind: 'wait' };
  }
}
