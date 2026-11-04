// Every tunable number for lyric detection, in one place. Override any of them in the library's
// settings file (thresholds), or with --set name=value in scripts/replay-lyrics.mjs.
// See "Tuning" in the README. These were tuned on synthetic transcripts, not a real choir.
export const DEFAULT_THRESHOLDS = {
  // Song detection
  windowMs: 25_000, // how much recent transcript is matched against song lines
  memoryMs: 45_000, // how long a matched line keeps counting towards a song
  minLineCoverage: 0.6, // how much of a line must be heard for it to count
  minLineWords: 3, // fewer matched words than this never counts (unless the line is shorter)
  scoreScale: 1.2, // higher means more matched lines are needed for the same confidence
  marginPenalty: 0.8, // how much a close runner-up reduces confidence
  suggestThreshold: 0.2, // below this, a song isn't even suggested
  autoThreshold: 0.75, // at or above this, a song can be proposed for display
  minDistinctLines: 2, // distinct, non-shared lines needed before a song can be proposed
  minConsecutiveWindows: 2, // consecutive transcript updates with a match needed before proposing

  // Transcript clean-up
  minWordConfidence: 0.25, // words the speech engine is less sure of than this are dropped
  maxPhraseRepeats: 3, // a phrase looping more than this inside one result is cut back

  // Position tracking
  advanceCoverage: 0.5, // how much of the next line must be heard to move on
  skipAheadLines: 2, // lines just past the next one can be reached directly, if one went unheard
  skipCoverage: 0.6, // how much of such a line must be heard
  stayCoverage: 0.6, // how much of the current line must be heard to count as a repeat
  jumpCoverage: 0.7, // how much of another line must be heard to consider jumping there
  strongJumpCoverage: 0.85, // a jump this clear, on a line found in only one section, needs no support
  strongJumpWords: 5,
  jumpConfirmMs: 15_000, // how long a possible jump waits for a supporting line
  tailMs: 20_000, // unmatched words older than this are forgotten

  // Song end and change
  staleClearMs: 30_000, // no lyric matched for this long: take lyrics off the screen, keep the song
  songEndMs: 75_000, // no lyric matched for this long: the song is over
  changeNoMatchMs: 10_000, // the current song must have gone quiet this long before another replaces it

  // Telling worship from preaching
  evidenceWindowMs: 90_000,
  worshipSustainMs: 30_000, // lyrics must hold this long before Auto-detect switches to worship
  worshipLyricShare: 0.5,
  sermonSustainMs: 75_000, // non-lyric speech must hold this long to count as preaching
  sermonMaxLyricShare: 0.15,
  sermonMinWordsPerMinute: 100, // singing is usually slower than this, speech usually faster
  asideLyricShare: 0.6, // a reference in a result this full of lyrics is treated as a lyric
};

export function resolveThresholds(overrides = {}) {
  const resolved = { ...DEFAULT_THRESHOLDS };
  for (const [key, value] of Object.entries(overrides ?? {})) {
    if (key in DEFAULT_THRESHOLDS && Number.isFinite(Number(value))) resolved[key] = Number(value);
  }
  return resolved;
}
