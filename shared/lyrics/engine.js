// Lyric detection without any browser or timer code, so the live app and the replay harness run
// exactly the same logic. Feed it final transcript results and call tick() regularly.
import { resolveThresholds } from './config.js';
import { SongDetector } from './songDetector.js';
import { arrangementOf } from './songs.js';
import { cleanTranscript, normalizeWords } from './text.js';

export class LyricsEngine {
  constructor({ thresholds, now = () => Date.now(), onEvent = () => {} } = {}) {
    this.t = resolveThresholds(thresholds);
    this.now = now;
    this.onEvent = onEvent;
    this.detector = new SongDetector({ thresholds: this.t, now });
    this.locked = null;
    this.lastProposal = null;
    this.lastLyricShare = 0;
  }

  setSongs(songs) {
    this.detector.setSongs(songs);
  }

  setThresholds(thresholds) {
    this.t = resolveThresholds(thresholds);
    this.detector.t = this.t;
  }

  addFinal({ text, words }) {
    const tokens = cleanTranscript(text, { words, minWordConfidence: this.t.minWordConfidence, maxPhraseRepeats: this.t.maxPhraseRepeats });
    if (!tokens.length) return { lyricShare: 0, tokens };
    const { candidates, lyricShare } = this.detector.update(tokens);
    this.lastLyricShare = lyricShare;
    this.afterUpdate(tokens, candidates);
    return { lyricShare, tokens };
  }

  afterUpdate(tokens, candidates) {
    const others = candidates.filter((c) => c.songId !== this.locked?.songId);
    this.onEvent({ type: 'candidates', candidates: others });
    if (this.locked) return;
    const top = others[0];
    if (top?.eligible) {
      this.lastProposal = top.songId;
      this.onEvent({ type: 'proposal', ...top, startIndex: this.startIndexFor(top) });
    }
  }

  startIndexFor(candidate) {
    const song = this.detector.songById(candidate.songId);
    if (!song) return 0;
    const arrangement = arrangementOf(song);
    const found = arrangement.find((line) => normalizeWords(line.text).join(' ') === candidate.lastLineKey);
    return found?.index ?? 0;
  }

  lock(songId, { index = 0, byOperator = false } = {}) {
    const song = this.detector.songById(songId);
    this.locked = { songId, song, index, byOperator, lockedAt: this.now() };
    this.onEvent({ type: 'locked', songId, index });
  }

  unlock() {
    this.locked = null;
    this.onEvent({ type: 'unlocked' });
  }

  reject(songId) {
    this.detector.reject(songId);
    this.onEvent({ type: 'candidates', candidates: [] });
  }

  tick() {}

  // Whether a detected Bible reference is really just words of a song.
  isLyricPhrase(phrase) {
    return this.lastLyricShare >= this.t.asideLyricShare || this.detector.containsPhrase(normalizeWords(phrase));
  }
}
