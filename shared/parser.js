// Step 2: run regexes over normalized text and work out what each match could mean.
// Nothing here knows about time or transcripts; detector.js handles that.
import { SINGLE_CHAPTER_BOOKS, bookById } from './books.js';
import { BOOK_KEYS, normalizeTranscript } from './normalize.js';
import { chapterRef, refKey, verseRef } from './references.js';
import { validateRef } from './validate.js';

const BOOK = BOOK_KEYS.join('|');
const VERSE_FILLER = '(?:(?:and|at|in|from|(?:beginning|starting) (?:at|with|in|from)) )?';

// book [chapter] N
const RE_FORWARD = new RegExp(`(?<![\\w¶])(${BOOK})((?: the)? chapter| number)? (\\d+)`, 'g');
// book verse N, for one-chapter books: "Jude verse three"
const RE_BOOK_VERSE = new RegExp(`(?<![\\w¶])(${BOOK})(?= verses? \\d)`, 'g');
// chapter N of book
const RE_CHAPTER_OF = new RegExp(`(?<![\\w¶])chapter (\\d+) of (?:the )?(?:book of )?(${BOOK})`, 'g');
// verse N of book [chapter] C
const RE_VERSE_OF = new RegExp(`(?<![\\w¶])verses? (\\d+)(?: (?:to|and) (\\d+))? (?:of|in) (${BOOK})(?: chapter)? (\\d+)`, 'g');
// bare "chapter five" or "verse seventeen", only meaningful with a recent reference for context
const RE_CONTEXT = /(?<![\w¶])(chapter|verses?) (\d+)/g;

const RE_VERSE_START = new RegExp(`(?: ${VERSE_FILLER}(verses?))? (\\d+)`, 'y');
const RE_VERSE_NEXT = /(?: (to|and)(?: verses?)?)? (\d+)/y;

// Words after a number that show it's a count rather than a chapter: "John three times".
const COUNTING_WORDS = new Set(['times', 'time', 'of', 'people', 'men', 'women', 'days', 'day', 'years', 'year', 'months', 'weeks', 'hours', 'minutes', 'disciples', 'more', 'or', 'children', 'sons', 'daughters', 'things', 'ways', 'points', 'others', 'friends', 'brothers', 'sisters', 'loaves', 'fish', 'percent', 'dollars', 'miles', 'oclock', 'am', 'pm', 'who', 'were', 'are']);
// Words before a name that show it's a person: "Pastor John three weeks ago".
const TITLE_WORDS = new Set(['pastor', 'brother', 'sister', 'pope', 'king', 'bishop', 'father', 'elder', 'deacon', 'mr', 'mrs', 'ms', 'dr', 'doctor', 'reverend', 'uncle', 'aunt', 'my', 'named', 'called']);

function isFollowedByCountingWord(tokens, tokenIndex) {
  return COUNTING_WORDS.has(tokens[tokenIndex + 1]?.text);
}

// Reads what follows a chapter number: verses, ranges and lists. Stops at the first thing that
// doesn't belong, so "John three sixteen and three other things" ends after sixteen.
function parseVerseTail(text, position) {
  RE_VERSE_START.lastIndex = position;
  const first = RE_VERSE_START.exec(text);
  if (!first) return null;
  return { ...parseVerseList(text, Number(first[2]), RE_VERSE_START.lastIndex, first[1] === 'verses'), marked: first[1] != null };
}

function parseVerseList(text, firstVerse, position, plural) {
  const ranges = [{ start: firstVerse, end: firstVerse }];
  let end = position;
  let crossChapter = false;
  for (;;) {
    RE_VERSE_NEXT.lastIndex = end;
    const next = RE_VERSE_NEXT.exec(text);
    if (!next) break;
    const [, joiner, digits] = next;
    const value = Number(digits);
    const current = ranges.at(-1);
    if (joiner === 'to') {
      if (value <= current.end) { crossChapter = true; break; } // "John 3:16 to 4:2"
      current.end = value;
    } else if (value === current.end + 1) {
      current.end = value;
    } else if (plural && value > current.end) {
      ranges.push({ start: value, end: value });
    } else {
      break;
    }
    end = RE_VERSE_NEXT.lastIndex;
  }
  return { ranges, end, crossChapter };
}

// Finds every candidate in normalized text. Spans never overlap; more specific patterns win.
export function findCandidates(normalized) {
  const { text, tokens, startIndex, endIndex } = normalized;
  const candidates = [];
  const overlaps = (start, end) => candidates.some((c) => start < c.charEnd && end > c.charStart);
  const add = (candidate) => {
    if (overlaps(candidate.charStart, candidate.charEnd)) return;
    const first = startIndex.get(candidate.charStart);
    const last = endIndex.get(candidate.charEnd);
    if (first == null || last == null) return;
    candidates.push({ ...candidate, firstToken: first, lastToken: last, start: tokens[first].start, end: tokens[last].end });
  };
  const bookTokenAt = (charOffset) => {
    const token = tokens[startIndex.get(charOffset)];
    return token?.kind === 'book' ? token.book : null;
  };
  const numberToken = (charOffset) => tokens[startIndex.get(charOffset)];

  for (const match of text.matchAll(RE_VERSE_OF)) {
    const book = bookTokenAt(match.index + match[0].indexOf(` ${match[3]}`) + 1);
    if (!book) continue;
    const start = Number(match[1]);
    add({
      type: 'reference', book, charStart: match.index, charEnd: match.index + match[0].length,
      chapterValue: Number(match[4]), ranges: [{ start, end: match[2] ? Number(match[2]) : start }],
      chapterWord: true, marked: true,
    });
  }

  for (const match of text.matchAll(RE_CHAPTER_OF)) {
    const bookOffset = match.index + match[0].length - match[2].length;
    const book = bookTokenAt(bookOffset);
    if (!book) continue;
    const tail = parseVerseTail(text, match.index + match[0].length);
    add({
      type: 'reference', book, charStart: match.index, charEnd: tail?.end ?? match.index + match[0].length,
      chapterValue: Number(match[1]), ranges: tail?.ranges ?? [], chapterWord: true, marked: tail?.marked, crossChapter: tail?.crossChapter,
    });
  }

  for (const match of text.matchAll(RE_FORWARD)) {
    const book = bookTokenAt(match.index);
    if (!book) continue;
    const headEnd = match.index + match[0].length;
    const chapterToken = numberToken(headEnd - match[3].length);
    let chapterValue = Number(match[3]);
    let tail = parseVerseTail(text, headEnd);
    let splitFromHundreds = false;

    // "Psalm one nineteen" means Psalm 119 (Psalm 1 only has six verses).
    if (book.ids[0] === 'PSA' && chapterValue === 1 && tail && !tail.marked && tail.ranges[0].start >= 10 && tail.ranges[0].start <= 50) {
      chapterValue = 100 + tail.ranges[0].start;
      const firstVerseDigits = String(tail.ranges[0].start);
      const after = headEnd + 1 + firstVerseDigits.length;
      tail = parseVerseTail(text, after) ?? { ranges: [], end: after };
      splitFromHundreds = true;
    }

    const charEnd = tail?.end ?? headEnd;
    const nextWord = tokens[endIndex.get(charEnd) + 1]?.text;
    add({
      type: 'reference', book, charStart: match.index, charEnd,
      chapterValue, ranges: tail?.ranges ?? [], compound: tail || splitFromHundreds ? null : chapterToken?.compound,
      chapterWord: Boolean(match[2]), marked: tail?.marked, crossChapter: tail?.crossChapter,
      chapterRange: !tail && nextWord === 'to',
      numberBreak: chapterToken?.breakBefore,
    });
  }

  for (const match of text.matchAll(RE_BOOK_VERSE)) {
    const book = bookTokenAt(match.index);
    if (!book) continue;
    const tail = parseVerseTail(text, match.index + match[0].length);
    if (!tail) continue;
    add({
      type: 'reference', book, charStart: match.index, charEnd: tail.end,
      chapterValue: null, ranges: tail.ranges, marked: true,
    });
  }

  for (const match of text.matchAll(RE_CONTEXT)) {
    const charStart = match.index;
    if (overlaps(charStart, charStart + match[0].length)) continue;
    const headEnd = charStart + match[0].length;
    if (match[1] === 'chapter') {
      const tail = parseVerseTail(text, headEnd);
      add({ type: 'contextChapter', charStart, charEnd: tail?.end ?? headEnd, chapterValue: Number(match[2]), ranges: tail?.ranges ?? [] });
    } else {
      const list = parseVerseList(text, Number(match[2]), headEnd, match[1] === 'verses');
      add({ type: 'contextVerse', charStart, charEnd: list.end, ranges: list.ranges });
    }
  }

  return candidates.sort((a, b) => a.start - b.start);
}

function refsFor(bookId, chapter, ranges) {
  if (!ranges.length) return [chapterRef(bookId, chapter)];
  return ranges.map((range) => verseRef(bookId, chapter, range.start, range.end));
}

// Every way of reading a candidate for one book, most natural first.
function readingsFor(bookId, candidate) {
  const { chapterValue, ranges, compound } = candidate;
  if (SINGLE_CHAPTER_BOOKS.has(bookId)) {
    // "Jude three" is verse 3; "Jude one twenty" is 1:20; "Jude one" is the whole book.
    if (chapterValue == null) return [refsFor(bookId, 1, ranges)];
    if (ranges.length) return [refsFor(bookId, chapterValue, ranges)];
    return chapterValue === 1 ? [[chapterRef(bookId, 1)]] : [[verseRef(bookId, 1, chapterValue)]];
  }
  if (chapterValue == null) return [];
  const readings = [refsFor(bookId, chapterValue, ranges)];
  if (compound) readings.push([verseRef(bookId, compound[0], compound[1])]); // "twenty three" -> 20:3
  return readings;
}

function detection(status, refs, candidate, phrase, reasons, alternates = []) {
  return {
    status, // 'confirmed' | 'suggestion' | 'invalid'
    refs,
    alternates,
    key: refs.map(refKey).join('|'),
    phrase,
    reasons,
    start: candidate.start,
    end: candidate.end,
  };
}

// Turns a candidate into detections. Returns [] for matches that aren't references at all.
//   versification: the translation being validated against
//   context: { book, chapter } of the most recent reference, for "verse seventeen"
//   manual: typed by the operator, so the guards against ordinary speech don't apply
export function interpretCandidate(candidate, { versification, context = null, manual = false, phrase = '', tokens = [] }) {
  if (candidate.type === 'contextVerse' || candidate.type === 'contextChapter') {
    if (!context) return [];
    const reason = `Assumed ${bookById(context.book)?.name ?? context.book} from the previous reference.`;
    const chapter = candidate.type === 'contextVerse' ? context.chapter : candidate.chapterValue;
    const refs = refsFor(context.book, chapter, candidate.ranges);
    return refs
      .filter((ref) => validateRef(ref, versification).ok)
      .map((ref) => detection('suggestion', [ref], candidate, phrase, [reason]));
  }

  const { book } = candidate;
  const chapterOnly = !candidate.ranges.length;
  const isNamelike = !book.numbered && book.ids.some((id) => bookById(id)?.commonWord);
  const unprompted = chapterOnly && !candidate.chapterWord && !book.cued;

  if (!manual && unprompted && (isNamelike || book.bare)) {
    if (isFollowedByCountingWord(tokens, candidate.lastToken)) return [];
    if (TITLE_WORDS.has(tokens[candidate.firstToken - 1]?.text)) return [];
    if (candidate.numberBreak) return [];
  }

  const options = [];
  const invalidReasons = [];
  let usedFallback = false;
  for (const id of book.ids) {
    const readings = readingsFor(id, candidate);
    readings.forEach((refs, index) => {
      const results = refs.map((ref) => validateRef(ref, versification));
      const failed = results.find((result) => !result.ok);
      if (failed) { invalidReasons.push({ id, refs, reason: failed.reason }); return; }
      if (index > 0 && options.length === 0) usedFallback = true;
      options.push(refs);
    });
  }

  if (!options.length) {
    const first = invalidReasons[0];
    const refs = first?.refs ?? [];
    if (!refs.length) return [];
    return [detection('invalid', [refs[0]], candidate, phrase, [first.reason])];
  }

  const reasons = [];
  if (!manual) {
    if (book.bare) reasons.push(`The book's number wasn't heard (“${book.heard}”). Please confirm which one.`);
    if (book.misheard || book.fuzzy) reasons.push(`Heard “${book.heard}”, which may be a transcription error.`);
    if (usedFallback) reasons.push(`Read as a chapter and verse because that chapter doesn't exist.`);
    if (candidate.crossChapter) reasons.push(`The passage may continue into another chapter. Only the first part was recognized.`);
    if (candidate.chapterRange) reasons.push(`Multiple chapters may have been meant. Only the first was recognized.`);
    if (isNamelike && unprompted && !usedFallback) reasons.push(`“${book.heard}” followed by one number could be ordinary speech.`);
  }

  const status = reasons.length ? 'suggestion' : 'confirmed';
  const [primary, ...others] = options;

  // Separate ranges ("verses four and six") become separate detections.
  if (primary.length > 1) {
    return primary.map((ref) => detection(status, [ref], candidate, phrase, reasons));
  }
  if (book.bare) {
    // Every reading is an equal choice, shown as options on one card.
    return [detection(status, options.map((refs) => refs[0]), candidate, phrase, reasons)];
  }
  return [detection(status, primary, candidate, phrase, reasons, others.map((refs) => refs[0]))];
}

// One-shot parsing for the operator's search box: "1 cor 13:4-7", "first corinthians thirteen".
export function parseManualReference(text, versification) {
  const normalized = normalizeTranscript(text, { manual: true });
  const candidate = findCandidates(normalized).find((c) => c.type === 'reference');
  if (!candidate) return { error: `Couldn't read “${text}” as a Bible reference.` };
  const [result] = interpretCandidate(candidate, { versification, manual: true, tokens: normalized.tokens, phrase: text });
  if (!result) return { error: `Couldn't read “${text}” as a Bible reference.` };
  if (result.status === 'invalid') return { error: result.reasons[0], refs: result.refs };
  return { refs: result.refs, alternates: result.alternates };
}

