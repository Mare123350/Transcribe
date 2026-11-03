import { CANONICAL_VERSIFICATION } from '../../shared/versification.js';
import { BibleError } from './errors.js';

// Remote translations are checked against the shared table for books and chapters; the provider
// has the last word on verses. See shared/validate.js.
export const approximateVersification = { exact: false, books: CANONICAL_VERSIFICATION };

// Keeps recent passages so repeat lookups don't spend quota. Limited by total verses because
// licences cap this: Crossway allows 500 cached ESV verses.
export class PassageCache {
  constructor(maxVerses = 500) {
    this.maxVerses = maxVerses;
    this.entries = new Map();
    this.total = 0;
  }

  get(key) {
    const value = this.entries.get(key);
    if (value) {
      this.entries.delete(key);
      this.entries.set(key, value);
    }
    return value;
  }

  set(key, value) {
    const size = value.verses.length;
    if (size > this.maxVerses || this.entries.has(key)) return;
    this.entries.set(key, value);
    this.total += size;
    for (const [oldKey, old] of this.entries) {
      if (this.total <= this.maxVerses) break;
      this.entries.delete(oldKey);
      this.total -= old.verses.length;
    }
  }
}

export async function fetchJson(fetchImpl, url, headers, { label, timeoutMs = 8000 }) {
  let response;
  try {
    response = await fetchImpl(url, { headers, signal: AbortSignal.timeout(timeoutMs) });
  } catch {
    throw new BibleError('upstream', `Couldn't reach ${label}. Check the internet connection.`);
  }
  if (response.status === 401 || response.status === 403) {
    throw new BibleError('unavailable', `${label} refused access. Check the API key and licence for this translation.`);
  }
  if (response.status === 404) throw new BibleError('not_found', 'not_found');
  if (response.status === 429) throw new BibleError('upstream', `${label} rate limit reached. Try again shortly.`);
  if (!response.ok) throw new BibleError('upstream', `${label} returned an error (${response.status}).`);
  try {
    return await response.json();
  } catch {
    throw new BibleError('upstream', `${label} sent a response that couldn't be read.`);
  }
}

// Splits provider text marked "[16] For God ... [17] For God sent..." into verses.
export function parseMarkedVerses(text, firstVerse) {
  const verses = [];
  const marker = /\[(\d+)\]/g;
  let previous = null;
  for (const match of text.matchAll(marker)) {
    if (previous) verses.push({ verse: previous.verse, text: clean(text.slice(previous.from, match.index)) });
    previous = { verse: Number(match[1]), from: match.index + match[0].length };
  }
  if (previous) verses.push({ verse: previous.verse, text: clean(text.slice(previous.from)) });
  else if (clean(text)) verses.push({ verse: firstVerse, text: clean(text) });
  return verses.filter((v) => v.text);
}

const clean = (text) => text.replace(/\s+/g, ' ').trim();
