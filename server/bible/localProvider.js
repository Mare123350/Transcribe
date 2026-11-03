import { readFile } from 'node:fs/promises';
import { join } from 'node:path';
import { formatRef, isWholeChapter } from '../../shared/references.js';
import { BibleError } from './errors.js';

// Serves a bundled public-domain text. Works with no network, and its verse table is exact.
export async function createLocalProvider(translation, dataDir) {
  const { books } = JSON.parse(await readFile(join(dataDir, translation.file), 'utf8'));
  const versification = {
    exact: true,
    books: Object.fromEntries(Object.entries(books).map(([id, chapters]) => [id, chapters.map((c) => c.length)])),
  };

  return {
    available: true,
    versification: () => versification,
    async getPassage(ref) {
      const chapter = books[ref.book]?.[ref.chapter - 1];
      if (!chapter) throw new BibleError('not_found', `${formatRef(ref)} is not in the ${translation.abbreviation}.`);
      const first = isWholeChapter(ref) ? 1 : ref.verseStart;
      const last = isWholeChapter(ref) ? chapter.length : ref.verseEnd;
      if (last > chapter.length) throw new BibleError('not_found', `${formatRef(ref)} is not in the ${translation.abbreviation}.`);

      const verses = [];
      const omitted = [];
      for (let verse = first; verse <= last; verse++) {
        const text = chapter[verse - 1];
        if (text) verses.push({ verse, text });
        else omitted.push(verse); // some translations leave out verses found in others, e.g. Acts 8:37
      }
      if (!verses.length) throw new BibleError('not_found', `${formatRef(ref)} is not in the text of the ${translation.abbreviation}.`);
      return { verses, omitted, copyright: translation.copyright };
    },
  };
}
