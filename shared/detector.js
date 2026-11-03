// Step 3: the rolling transcript. Takes interim and final results as they arrive and decides when
// a reference is complete enough to report, exactly once.
//
// - Only final text can trigger a detection. Interim text is reported as tentative, for display only.
// - A match at the very end of the transcript might still grow ("John three" ... "sixteen"), so it's
//   held until more words arrive or `settleMs` passes.
// - `consumedUpTo` records how far detections have been handled, so rescans never repeat one.
// - A reference said again within `cooldownMs` is reported through onRepeat instead of onDetection.
import { findCandidates, interpretCandidate } from './parser.js';
import { normalizeTranscript } from './normalize.js';

const CONNECTOR_WORDS = new Set(['verse', 'verses', 'to', 'and', 'chapter', 'number', 'the', 'at', 'from']);

export class ReferenceDetector {
  constructor({
    versification,
    onDetection = () => {},
    onRepeat = () => {},
    onTentative = () => {},
    settleMs = 1200,
    cooldownMs = 45_000,
    gapMs = 8_000,
    contextMs = 120_000,
    maxChars = 2_000,
    now = () => Date.now(),
    setTimer = (fn, ms) => setTimeout(fn, ms),
    clearTimer = (handle) => clearTimeout(handle),
  }) {
    Object.assign(this, { versification, onDetection, onRepeat, onTentative, settleMs, cooldownMs, gapMs, contextMs, maxChars, now, setTimer, clearTimer });
    this.reset();
  }

  reset() {
    if (this.timer != null) this.clearTimer(this.timer);
    this.timer = null;
    this.finalText = '';
    this.interimText = '';
    this.base = 0; // absolute offset of finalText[0], since old text gets trimmed
    this.consumedUpTo = 0;
    this.lastFinalAt = null;
    this.context = null;
    this.seen = new Map();
    this.lastTentative = '';
  }

  setVersification(versification) {
    this.versification = versification;
  }

  addInterim(text) {
    this.interimText = text.trim();
    this.process();
    this.reportTentative();
  }

  addFinal(text) {
    const clean = text.trim();
    this.interimText = '';
    if (clean) {
      const at = this.now();
      // After a long silence, a book name and a stray number shouldn't join into a reference.
      const gap = this.lastFinalAt != null && at - this.lastFinalAt > this.gapMs;
      this.finalText += `${this.finalText ? ' ' : ''}${gap ? '¶ ' : ''}${clean}`;
      this.lastFinalAt = at;
      this.trim();
    }
    this.process();
    this.reportTentative();
  }

  // Reports anything still being held, e.g. when the operator pauses or stops.
  flush() {
    this.interimText = '';
    this.process({ force: true });
    this.reportTentative();
  }

  trim() {
    if (this.finalText.length <= this.maxChars) return;
    let cut = this.finalText.length - Math.floor(this.maxChars / 2);
    const space = this.finalText.indexOf(' ', cut);
    if (space > 0) cut = space + 1;
    this.finalText = this.finalText.slice(cut);
    this.base += cut;
  }

  scan(text) {
    const normalized = normalizeTranscript(text);
    const consumed = this.consumedUpTo - this.base;
    const candidates = findCandidates(normalized).filter((c) => c.start >= consumed);
    return { normalized, candidates };
  }

  isAtTail(candidate, tokens) {
    for (let i = candidate.lastToken + 1; i < tokens.length; i++) {
      if (!CONNECTOR_WORDS.has(tokens[i].text)) return false;
    }
    return true;
  }

  process({ force = false } = {}) {
    if (this.timer != null) {
      this.clearTimer(this.timer);
      this.timer = null;
    }
    const { normalized, candidates } = this.scan(this.finalText);

    for (const candidate of candidates) {
      if (!force && this.isAtTail(candidate, normalized.tokens)) {
        if (this.interimResolves(candidate)) {
          this.commit(candidate, normalized);
          continue;
        }
        this.timer = this.setTimer(() => {
          this.timer = null;
          this.process({ force: true });
          this.reportTentative();
        }, this.settleMs);
        return;
      }
      this.commit(candidate, normalized);
    }
  }

  // True when interim words show that a held reference has finished: real words follow it and it
  // didn't grow. If it's growing, keep waiting for the final result.
  interimResolves(candidate) {
    if (!this.interimText) return false;
    const { normalized, candidates } = this.scan(`${this.finalText} ${this.interimText}`);
    const same = candidates.find((c) => c.start === candidate.start);
    if (!same || same.end !== candidate.end) return false;
    return !this.isAtTail(same, normalized.tokens);
  }

  interpret(candidate, normalized, text) {
    const context = this.context && this.now() - this.context.at <= this.contextMs ? this.context : null;
    return interpretCandidate(candidate, {
      versification: this.versification,
      context,
      tokens: normalized.tokens,
      phrase: text.slice(candidate.start, candidate.end),
    });
  }

  commit(candidate, normalized) {
    this.consumedUpTo = this.base + candidate.end;
    for (const result of this.interpret(candidate, normalized, this.finalText)) {
      if (result.status !== 'invalid') {
        const { book, chapter } = result.refs[0];
        this.context = { book, chapter, at: this.now() };
      }
      const at = this.now();
      const last = this.seen.get(result.key);
      if (last != null && at - last < this.cooldownMs) {
        this.onRepeat(result);
        continue;
      }
      this.seen.set(result.key, at);
      this.onDetection(result);
    }
  }

  reportTentative() {
    const text = this.interimText ? `${this.finalText} ${this.interimText}` : this.finalText;
    const { normalized, candidates } = this.scan(text);
    const tentative = candidates
      .flatMap((candidate) => this.interpret(candidate, normalized, text))
      .filter((result) => result.status !== 'invalid');
    const signature = tentative.map((t) => t.key).join(',');
    if (signature === this.lastTentative) return;
    this.lastTentative = signature;
    this.onTentative(tentative);
  }
}
