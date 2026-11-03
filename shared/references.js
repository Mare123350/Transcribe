// The reference model and helpers. A reference is { book, chapter, verseStart, verseEnd };
// verseStart is null for a whole chapter.
import { displayBookName, SINGLE_CHAPTER_BOOKS } from './books.js';

export const chapterRef = (book, chapter) => ({ book, chapter, verseStart: null, verseEnd: null });
export const verseRef = (book, chapter, verseStart, verseEnd = verseStart) => ({ book, chapter, verseStart, verseEnd });

export const isWholeChapter = (ref) => ref.verseStart == null;

export function refKey(ref) {
  const base = `${ref.book}.${ref.chapter}`;
  if (isWholeChapter(ref)) return base;
  return ref.verseEnd === ref.verseStart ? `${base}.${ref.verseStart}` : `${base}.${ref.verseStart}-${ref.verseEnd}`;
}

const KEY_RE = /^([1-3A-Z][A-Z]{2})\.(\d{1,3})(?:\.(\d{1,3})(?:-(\d{1,3}))?)?$/;

export function parseRefKey(key) {
  const match = KEY_RE.exec(String(key));
  if (!match) return null;
  const [, book, chapter, start, end] = match;
  if (start == null) return chapterRef(book, Number(chapter));
  return verseRef(book, Number(chapter), Number(start), end == null ? Number(start) : Number(end));
}

export function formatRef(ref) {
  const name = displayBookName(ref.book);
  if (isWholeChapter(ref)) return SINGLE_CHAPTER_BOOKS.has(ref.book) ? name : `${name} ${ref.chapter}`;
  const verses = ref.verseEnd === ref.verseStart ? `${ref.verseStart}` : `${ref.verseStart}–${ref.verseEnd}`;
  return `${name} ${ref.chapter}:${verses}`;
}

// The next or previous verse (or chapter, when showing a whole chapter), staying inside the book.
// Returns null at either end of the book.
export function adjacentRef(ref, direction, versification) {
  const chapters = versification.books[ref.book];
  if (!chapters) return null;
  if (isWholeChapter(ref)) {
    const chapter = ref.chapter + direction;
    return chapter >= 1 && chapter <= chapters.length ? chapterRef(ref.book, chapter) : null;
  }
  if (direction > 0) {
    if (ref.verseEnd < chapters[ref.chapter - 1]) return verseRef(ref.book, ref.chapter, ref.verseEnd + 1);
    return ref.chapter < chapters.length ? verseRef(ref.book, ref.chapter + 1, 1) : null;
  }
  if (ref.verseStart > 1) return verseRef(ref.book, ref.chapter, ref.verseStart - 1);
  return ref.chapter > 1 ? verseRef(ref.book, ref.chapter - 1, chapters[ref.chapter - 2]) : null;
}
