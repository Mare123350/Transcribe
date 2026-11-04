// Decides from sustained evidence whether the room is in worship or hearing preaching.
//   Worship:  most recent words are recognizably lyrics.
//   Preaching: a long stretch of words at talking pace with almost no lyrics.
// Anything brief, such as a verse mentioned between songs, can't change the answer, and neither can
// silence or a song missing from the library, which is why speaking pace is part of the test.
export class ActivityClassifier {
  constructor({ thresholds, now = () => Date.now(), initial = 'sermon' }) {
    this.t = thresholds;
    this.now = now;
    this.activity = initial;
    this.preachingLikely = false;
    this.samples = [];
  }

  // `items` are the words from one transcript update. They're kept by reference because a word is
  // only recognized as a lyric once enough of its line has arrived.
  add(items) {
    const at = this.now();
    this.samples.push({ at, items });
    this.samples = this.samples.filter((sample) => at - sample.at <= this.t.evidenceWindowMs);
    return this.evaluate();
  }

  stats(spanMs) {
    const at = this.now();
    const recent = this.samples.filter((sample) => at - sample.at <= spanMs);
    if (!recent.length) return null;
    const covered = at - recent[0].at;
    const words = recent.reduce((sum, sample) => sum + sample.items.length, 0);
    const lyricWords = recent.reduce((sum, sample) => sum + sample.items.filter((item) => item.lyric).length, 0);
    return {
      // Evidence must span most of the period, rather than one burst at the end of it.
      sustained: covered >= spanMs * 0.8,
      lyricShare: words ? lyricWords / words : 0,
      wordsPerMinute: covered > 0 ? words / (covered / 60_000) : 0,
    };
  }

  evaluate() {
    const worship = this.stats(this.t.worshipSustainMs);
    const sermon = this.stats(this.t.sermonSustainMs);
    const worshipNow = Boolean(worship?.sustained && worship.lyricShare >= this.t.worshipLyricShare);
    const preachingNow = Boolean(sermon?.sustained
      && sermon.lyricShare <= this.t.sermonMaxLyricShare
      && sermon.wordsPerMinute >= this.t.sermonMinWordsPerMinute);

    const result = { activity: this.activity, changed: false, preachingLikely: preachingNow, preachingChanged: preachingNow !== this.preachingLikely };
    this.preachingLikely = preachingNow;
    if (worshipNow && this.activity !== 'worship') {
      this.activity = 'worship';
      result.activity = 'worship';
      result.changed = true;
    } else if (preachingNow && this.activity !== 'sermon') {
      this.activity = 'sermon';
      result.activity = 'sermon';
      result.changed = true;
    }
    return result;
  }
}
