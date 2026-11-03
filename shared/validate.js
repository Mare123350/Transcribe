// Checks a reference against one translation's versification: { exact, books: { GEN: [31, 25, ...] } }.
// Licensed translations reached through an API report `exact: false`, because verse counts vary between
// translations (3 John has 14 verses in the KJV and 15 in the ESV). Past the table's end those are
// passed as `unverified`, and the provider's answer at lookup time decides.
import { displayBookName } from './books.js';

export function validateRef(ref, versification) {
  const chapters = versification.books[ref.book];
  const name = displayBookName(ref.book);
  if (!chapters) return { ok: false, reason: `${name} is not in this translation.` };
  if (ref.chapter < 1 || ref.chapter > chapters.length) {
    return { ok: false, reason: `${name} has ${chapters.length} chapter${chapters.length === 1 ? '' : 's'}, so there is no chapter ${ref.chapter}.` };
  }
  if (ref.verseStart == null) return { ok: true };

  const count = chapters[ref.chapter - 1];
  if (ref.verseStart < 1) return { ok: false, reason: `Verse numbers start at 1.` };
  if (ref.verseEnd < ref.verseStart) return { ok: false, reason: `That verse range runs backwards.` };
  if (ref.verseEnd > count) {
    if (!versification.exact) return { ok: true, unverified: true };
    return { ok: false, reason: `${name} ${ref.chapter} has ${count} verses, so there is no verse ${ref.verseEnd}.` };
  }
  return { ok: true };
}
