// Lyric detection without any browser or timer code, so the live app and the replay harness run
// exactly the same logic. Feed it final transcript results and call tick() regularly.
import { resolveThresholds } from './config.js';
import { PositionTracker } from './positionTracker.js';
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
    const at = this.now();
    const others = candidates.filter((c) => c.songId !== this.locked?.songId);
    this.onEvent({ type: 'candidates', candidates: others });

    if (!this.locked) {
      const top = others[0];
      if (top?.eligible) this.onEvent({ type: 'proposal', ...top, startIndex: this.startIndexFor(top) });
      return;
    }

    const { tracker } = this.locked;
    const heardBefore = tracker.lastMatchAt;
    const moved = tracker.update(tokens, at);
    if (tracker.lastMatchAt !== heardBefore) {
      this.locked.lastMatchAt = at;
      if (this.locked.quiet) {
        this.locked.quiet = false;
        this.onEvent({ type: 'resume', index: tracker.index });
      }
    }
    if (moved != null) this.onEvent({ type: 'position', index: moved });

    // Another song is taking over: it's confidently matched and the current one has gone quiet.
    const top = others[0];
    if (top?.eligible && at - this.locked.lastMatchAt >= this.t.changeNoMatchMs) {
      this.onEvent({ type: 'songChange', ...top, startIndex: this.startIndexFor(top), byOperator: this.locked.byOperator });
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
    const at = this.now();
    this.detector.forget(this.locked?.songId);
    this.detector.currentSongId = songId;
    this.locked = {
      songId,
      song,
      byOperator,
      lastMatchAt: at,
      quiet: false,
      tracker: song ? new PositionTracker(song, { thresholds: this.t, startIndex: index }) : null,
    };
    this.onEvent({ type: 'locked', songId, index });
  }

  unlock() {
    if (this.locked) this.detector.forget(this.locked.songId);
    this.detector.currentSongId = null;
    this.locked = null;
    this.onEvent({ type: 'unlocked' });
  }

  reject(songId) {
    this.detector.reject(songId);
    this.onEvent({ type: 'candidates', candidates: [] });
  }

  // Call regularly, even when no words are arriving: silence is what ends a song.
  tick() {
    if (!this.locked?.tracker) return;
    const silent = this.now() - this.locked.lastMatchAt;
    if (this.locked.byOperator) {
      // The operator chose this song, so silence is only reported, and nothing is taken away.
      if (silent >= this.t.staleClearMs && !this.locked.quiet) {
        this.locked.quiet = true;
        this.onEvent({ type: 'quiet', songId: this.locked.songId, byOperator: true });
      }
      return;
    }
    if (silent >= this.t.songEndMs) {
      const { songId } = this.locked;
      this.unlock();
      this.onEvent({ type: 'ended', songId });
    } else if (silent >= this.t.staleClearMs && !this.locked.quiet) {
      this.locked.quiet = true;
      this.onEvent({ type: 'quiet', songId: this.locked.songId });
    }
  }

  position() {
    return this.locked?.tracker ? { index: this.locked.tracker.index, repeats: this.locked.tracker.repeats } : null;
  }

  // The operator moved by hand. The tracker follows from there, so resuming auto-follow is accurate.
  setPosition(index) {
    if (!this.locked?.tracker) return;
    this.locked.tracker.index = index;
    this.locked.tracker.tail = [];
    this.locked.tracker.pending = null;
  }

  showing() {
    return Boolean(this.locked && !this.locked.quiet);
  }

  // Whether a detected Bible reference is really just words of a song.
  isLyricPhrase(phrase) {
    return this.lastLyricShare >= this.t.asideLyricShare || this.detector.containsPhrase(normalizeWords(phrase));
  }
}
