// Step 1 of detection: turn a raw transcript into a canonical form that simple regexes can read.
//   "First Corinthians thirteen, verses four to seven." -> "1 corinthians 13 verses 4 to 7"
// Every output token remembers where it came from in the raw text, so a match can be traced back
// to the transcript for highlighting and for tracking what has already been handled.
import { BOOKS, NUMBERED_BASES } from './books.js';

const UNITS = { one: 1, two: 2, three: 3, four: 4, five: 5, six: 6, seven: 7, eight: 8, nine: 9 };
const TEENS = { ten: 10, eleven: 11, twelve: 12, thirteen: 13, fourteen: 14, fifteen: 15, sixteen: 16, seventeen: 17, eighteen: 18, nineteen: 19 };
const TENS = { twenty: 20, thirty: 30, forty: 40, fourty: 40, fifty: 50, sixty: 60, seventy: 70, eighty: 80, ninety: 90 };
const ORDINAL_UNITS = { first: 1, second: 2, third: 3, fourth: 4, fifth: 5, sixth: 6, seventh: 7, eighth: 8, ninth: 9 };
const ORDINAL_TEENS = { tenth: 10, eleventh: 11, twelfth: 12, thirteenth: 13, fourteenth: 14, fifteenth: 15, sixteenth: 16, seventeenth: 17, eighteenth: 18, nineteenth: 19 };
const ORDINAL_TENS = { twentieth: 20, thirtieth: 30, fortieth: 40, fiftieth: 50, sixtieth: 60, seventieth: 70, eightieth: 80, ninetieth: 90 };

// Homophones are only read as numbers right after a book, a number, or "chapter"/"verse".
// "for" is deliberately absent: "John three for God so loved" must not become John 3:4.
const HOMOPHONES = { won: 1, ate: 8, fore: 4 };

const BOOK_PREFIXES = {
  first: 1, '1st': 1, 1: 1, one: 1, i: 1,
  second: 2, '2nd': 2, 2: 2, two: 2, too: 2, ii: 2,
  third: 3, '3rd': 3, 3: 3, three: 3, iii: 3,
};

// Words that can sit between a number prefix or a sentence and the book name.
const CUES = [
  'book of the prophet', 'the book of the prophet', 'the book of', 'book of',
  'the gospel according to saint', 'the gospel according to', 'gospel according to saint', 'gospel according to',
  'the gospel of saint', 'the gospel of', 'gospel of saint', 'gospel of',
  'letter to the', 'letter of', 'letter to', 'epistle to the', 'epistle of', 'epistle to', 'general epistle of',
  'saint', 'st', 'prophet',
].map((phrase) => phrase.split(' ')).sort((a, b) => b.length - a.length);

const KEYWORDS = { verse: 'verse', verses: 'verses', versus: 'verses', vs: 'verse', vv: 'verses', chapter: 'chapter', chapters: 'chapter', chap: 'chapter' };
const RANGE_WORDS = new Set(['through', 'thru', 'till', 'until', 'too']);

function buildAliasTables() {
  const live = new Map();
  const written = new Map();
  const add = (table, phrase, entry) => { if (!table.has(phrase)) table.set(phrase, entry); };
  for (const base of NUMBERED_BASES) {
    const entry = { key: base.key, base };
    add(live, base.key, entry);
    for (const alias of base.aliases) add(live, alias, entry);
    for (const alias of base.abbr) add(written, alias, entry);
  }
  for (const book of BOOKS) {
    if (/^\d/.test(book.id) || book.id === 'JHN') continue; // reached through NUMBERED_BASES
    const key = book.key ?? book.name.toLowerCase();
    const entry = { key, ids: [book.id] };
    add(live, key, entry);
    add(live, book.name.toLowerCase(), entry);
    for (const alias of book.aliases ?? []) add(live, alias, entry);
    for (const alias of book.misheard ?? []) add(live, alias, { ...entry, misheard: true });
    for (const alias of book.abbr ?? []) add(written, alias, entry);
  }
  return { live, written };
}

// Written abbreviations are separate because "sam" typed means Samuel, while "sam" heard is usually Psalm.
const { live: ALIASES, written: WRITTEN_ALIASES } = buildAliasTables();
const MAX_ALIAS_WORDS = 5;

// Long, distinctive names only: fuzzy matches near short names would fire on ordinary speech.
const FUZZY_TARGETS = [...new Set([...ALIASES.entries()]
  .filter(([phrase, entry]) => !entry.misheard && phrase.length >= 7 && !phrase.includes(' ') && !entry.base?.defaultId
    && !BOOKS.find((b) => b.commonWord && b.id === entry.ids?.[0]))
  .map(([phrase]) => phrase))];

// Canonical names the parser's regex matches on.
export const BOOK_KEYS = (() => {
  const keys = new Set(BOOKS.map((book) => book.key ?? book.name.toLowerCase()));
  for (const base of NUMBERED_BASES) keys.add(base.key);
  return [...keys].sort((a, b) => b.length - a.length);
})();

function editDistanceAtMost(a, b, limit) {
  if (Math.abs(a.length - b.length) > limit) return false;
  let previous = Array.from({ length: b.length + 1 }, (_, i) => i);
  for (let i = 1; i <= a.length; i++) {
    const current = [i];
    for (let j = 1; j <= b.length; j++) {
      current[j] = Math.min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] === b[j - 1] ? 0 : 1));
    }
    if (Math.min(...current) > limit) return false;
    previous = current;
  }
  return previous[b.length] <= limit;
}

const TOKEN_RE = /¶|\d+(?:st|nd|rd|th)?(?:[:.\-–—]\d+)*|\p{L}+(?:['’\-–]\p{L}+)*/gu;

export function tokenize(raw) {
  const tokens = [];
  let previousEnd = 0;
  for (const match of raw.matchAll(TOKEN_RE)) {
    const start = match.index;
    const end = start + match[0].length;
    const breakBefore = /[.?!]/.test(raw.slice(previousEnd, start));
    previousEnd = end;
    const text = match[0].toLowerCase().replace(/['’]s$/, '').replace(/['’]/g, '');
    if (/^\d+[:.\-–—]/.test(text)) {
      // "13:4-7" -> 13 verse 4 to 7, all sharing the span of the original token
      const parts = text.split(/([:.\-–—])/);
      parts.forEach((part, i) => {
        const word = i % 2 === 0 ? part : (/[:.]/.test(part) ? 'verse' : 'to');
        tokens.push({ text: word, start, end, breakBefore: i === 0 && breakBefore });
      });
    } else if (/[\-–]/.test(text)) {
      let offset = start;
      text.split(/[\-–]/).forEach((part, i) => {
        tokens.push({ text: part, start: offset, end: offset + part.length, breakBefore: i === 0 && breakBefore });
        offset += part.length + 1;
      });
    } else {
      tokens.push({ text, start, end, breakBefore });
    }
  }
  return tokens;
}

function matchesPhrase(src, i, words) {
  return words.every((word, k) => src[i + k]?.text === word);
}

function longestAlias(src, i, manual) {
  for (let length = MAX_ALIAS_WORDS; length >= 1; length--) {
    if (i + length > src.length) continue;
    const phrase = src.slice(i, i + length).map((t) => t.text).join(' ');
    const entry = (manual && WRITTEN_ALIASES.get(phrase)) || ALIASES.get(phrase);
    if (entry) return { entry, length };
  }
  return null;
}

function looksNumeric(token) {
  if (!token) return false;
  const text = token.text;
  return /^\d/.test(text) || text in UNITS || text in TEENS || text in TENS || text === 'chapter' || text === 'hundred';
}

function fuzzyAlias(src, i) {
  const word = src[i].text;
  if (word.length < 7 || !looksNumeric(src[i + 1])) return null;
  const limit = word.length >= 9 ? 2 : 1;
  const target = FUZZY_TARGETS.find((candidate) => editDistanceAtMost(word, candidate, limit));
  if (!target) return null;
  return { entry: ALIASES.get(target), length: 1, fuzzy: true };
}

// Recognizes a book name at src[i], including number prefixes and cue words like "gospel of".
function matchBook(src, i, { manual, allowPrefix }) {
  let j = i;
  let number = null;
  if (allowPrefix && BOOK_PREFIXES[src[i].text]) {
    number = BOOK_PREFIXES[src[i].text];
    j++;
  }
  let cued = false;
  const cue = CUES.find((words) => matchesPhrase(src, j, words));
  if (cue) { j += cue.length; cued = true; }
  if (j >= src.length) return null;

  const found = longestAlias(src, j, manual) ?? fuzzyAlias(src, j);
  if (!found) return null;

  const { entry, length, fuzzy } = found;
  const heard = src.slice(j, j + length).map((t) => t.text).join(' ');
  const end = j + length;
  const flags = { cued, heard, fuzzy: Boolean(fuzzy), misheard: Boolean(entry.misheard) };

  if (number) {
    const id = entry.base?.ids[number];
    if (!id) return null; // "second Romans" is not a book; let "second" fall through as a plain word
    return { end, book: { ...flags, key: `${number} ${entry.base.key}`, ids: [id], numbered: true } };
  }
  if (entry.base) {
    if (entry.base.defaultId) return { end, book: { ...flags, key: entry.base.key, ids: [entry.base.defaultId] } };
    return { end, book: { ...flags, key: entry.base.key, ids: Object.values(entry.base.ids), bare: true } };
  }
  return { end, book: { ...flags, key: entry.key, ids: entry.ids } };
}

// Reads one spoken number starting at src[i]. Returns { value, length, compound? } or null.
// A units word that is really a book prefix is left alone: "twenty two Timothy" is 20, then 2 Timothy.
function parseNumber(src, i, options) {
  const text = src[i]?.text;
  if (text == null) return null;
  const isPrefixOfBook = (index) => src[index] && matchBook(src, index, { ...options, allowPrefix: true })?.book.numbered;

  if (/^\d+$/.test(text)) return { value: Number(text), length: 1 };
  const suffixed = text.match(/^(\d+)(?:st|nd|rd|th)$/);
  if (suffixed) return { value: Number(suffixed[1]), length: 1 };

  // "one hundred and nineteen", "a hundred three", "hundred"
  const hundredAt = text === 'hundred' ? i : (src[i + 1]?.text === 'hundred' && (text === 'a' || text in UNITS) ? i + 1 : -1);
  if (hundredAt >= 0) {
    const multiplier = text in UNITS ? UNITS[text] : 1;
    let j = hundredAt + 1;
    if (src[j]?.text === 'and') j++;
    const rest = parseTensAndUnits(src, j, isPrefixOfBook);
    if (rest) return { value: multiplier * 100 + rest.value, length: j + rest.length - i };
    return { value: multiplier * 100, length: hundredAt + 1 - i };
  }

  // "one oh five" -> 105
  if (text === 'one' && ['oh', 'o', 'zero'].includes(src[i + 1]?.text) && src[i + 2]?.text in UNITS) {
    return { value: 100 + UNITS[src[i + 2].text], length: 3 };
  }

  return parseTensAndUnits(src, i, isPrefixOfBook);
}

function parseTensAndUnits(src, i, isPrefixOfBook) {
  const text = src[i]?.text;
  if (text == null) return null;
  if (text in TENS) {
    const next = src[i + 1]?.text;
    if (next in UNITS && !isPrefixOfBook(i + 1)) {
      return { value: TENS[text] + UNITS[next], length: 2, compound: [TENS[text], UNITS[next]] };
    }
    return { value: TENS[text], length: 1 };
  }
  if (text in TEENS) return { value: TEENS[text], length: 1 };
  if (text in UNITS) return { value: UNITS[text], length: 1 };
  return null;
}

// "the twenty third", "hundred and nineteenth", "sixteenth", "23rd"
function parseOrdinal(src, i) {
  const text = src[i]?.text;
  if (text == null) return null;
  const suffixed = text.match(/^(\d+)(?:st|nd|rd|th)$/);
  if (suffixed) return { value: Number(suffixed[1]), length: 1 };
  const small = (at) => {
    const word = src[at]?.text;
    if (word in ORDINAL_UNITS) return { value: ORDINAL_UNITS[word], length: 1 };
    if (word in ORDINAL_TEENS) return { value: ORDINAL_TEENS[word], length: 1 };
    if (word in ORDINAL_TENS) return { value: ORDINAL_TENS[word], length: 1 };
    if (word in TENS && src[at + 1]?.text in ORDINAL_UNITS) return { value: TENS[word] + ORDINAL_UNITS[src[at + 1].text], length: 2 };
    return null;
  };
  const hundredAt = text === 'hundred' ? i : (src[i + 1]?.text === 'hundred' && (text === 'one' || text === 'a') ? i + 1 : -1);
  if (hundredAt >= 0) {
    let j = hundredAt + 1;
    if (src[j]?.text === 'and') j++;
    const rest = small(j);
    return rest ? { value: 100 + rest.value, length: j + rest.length - i } : null;
  }
  return small(i);
}

const ORDINAL_TARGETS = new Set(['chapter', 'verse', 'psalm']);

export function normalizeTranscript(raw, { manual = false } = {}) {
  const src = tokenize(raw);
  const out = [];
  const options = { manual };
  const push = (kind, text, first, last, extra = {}) => {
    out.push({ kind, text, start: src[first].start, end: src[last].end, breakBefore: src[first].breakBefore, ...extra });
  };

  let i = 0;
  while (i < src.length) {
    const token = src[i];
    if (token.text === '¶') { push('break', '¶', i, i); i++; continue; }

    // "the third chapter", "the twenty third psalm", "sixteenth verse"
    const ordinal = parseOrdinal(src, i);
    if (ordinal && ORDINAL_TARGETS.has(src[i + ordinal.length]?.text)) {
      const target = src[i + ordinal.length].text;
      const last = i + ordinal.length;
      if (target === 'psalm') {
        push('book', 'psalm', i, last, { book: { key: 'psalm', ids: ['PSA'], cued: true, heard: 'psalm' } });
      } else {
        push('word', target, i, last);
      }
      push('number', String(ordinal.value), i, last, { value: ordinal.value });
      out.at(-1).breakBefore = false;
      i = last + 1;
      continue;
    }

    // A number straight after a book or "verse" is a number, not the start of a numbered book.
    const previous = out.at(-1);
    const allowPrefix = !(previous?.kind === 'book' || previous?.text === 'chapter' || previous?.text === 'verse' || previous?.text === 'verses');
    const bookMatch = matchBook(src, i, { manual, allowPrefix });
    if (bookMatch) {
      push('book', bookMatch.book.key, i, bookMatch.end - 1, { book: bookMatch.book });
      i = bookMatch.end;
      continue;
    }

    const number = parseNumber(src, i, options);
    if (number) {
      push('number', String(number.value), i, i + number.length - 1, { value: number.value, compound: number.compound });
      i += number.length;
      continue;
    }

    const inNumberContext = previous && (previous.kind === 'book' || previous.kind === 'number' || previous.text === 'chapter' || previous.text === 'verse' || previous.text === 'verses');
    if (inNumberContext && token.text in HOMOPHONES) {
      push('number', String(HOMOPHONES[token.text]), i, i, { value: HOMOPHONES[token.text] });
      i++;
      continue;
    }

    if (token.text in KEYWORDS && (token.text !== 'vs' || manual || inNumberContext)) {
      push('word', KEYWORDS[token.text], i, i);
    } else if (previous?.kind === 'number' && RANGE_WORDS.has(token.text)) {
      push('word', 'to', i, i);
    } else {
      push('word', token.text, i, i);
    }
    i++;
  }

  // Join into the string the regexes run over, and index tokens by character offset.
  let text = '';
  const startIndex = new Map();
  const endIndex = new Map();
  out.forEach((t, index) => {
    if (index > 0) text += ' ';
    startIndex.set(text.length, index);
    text += t.text;
    endIndex.set(text.length, index);
  });
  return { text, tokens: out, startIndex, endIndex };
}
