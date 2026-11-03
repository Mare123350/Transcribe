import { bookById } from '../../shared/books.js';
import { isWholeChapter, refKey, formatRef } from '../../shared/references.js';
import { BibleError } from './errors.js';
import { PassageCache, approximateVersification, fetchJson, parseMarkedVerses } from './remoteHelpers.js';

const URL_BASE = 'https://api.esv.org/v3/passage/text/';

function query(ref) {
  const name = bookById(ref.book).name;
  if (isWholeChapter(ref)) return `${name} ${ref.chapter}`;
  return ref.verseStart === ref.verseEnd
    ? `${name} ${ref.chapter}:${ref.verseStart}`
    : `${name} ${ref.chapter}:${ref.verseStart}-${ref.verseEnd}`;
}

export function createEsvProvider(translation, { apiKey, fetchImpl = fetch }) {
  const cache = new PassageCache(500); // Crossway's limit on locally cached verses
  return {
    available: true,
    versification: () => approximateVersification,
    async getPassage(ref) {
      const key = refKey(ref);
      const cached = cache.get(key);
      if (cached) return cached;

      const params = new URLSearchParams({
        q: query(ref),
        'include-passage-references': 'false',
        'include-footnotes': 'false',
        'include-footnote-body': 'false',
        'include-headings': 'false',
        'include-short-copyright': 'false',
        'include-verse-numbers': 'true',
        'include-first-verse-numbers': 'true',
        'indent-paragraphs': '0',
        'indent-poetry': 'false',
      });
      const body = await fetchJson(fetchImpl, `${URL_BASE}?${params}`, { Authorization: `Token ${apiKey}` }, { label: 'the ESV API' })
        .catch((error) => {
          if (error.code === 'not_found') throw new BibleError('not_found', `${formatRef(ref)} is not in the ${translation.abbreviation}.`);
          throw error;
        });
      const verses = parseMarkedVerses(body?.passages?.join(' ') ?? '', ref.verseStart ?? 1);
      if (!verses.length) throw new BibleError('not_found', `${formatRef(ref)} is not in the ${translation.abbreviation}.`);
      const passage = { verses, omitted: [], copyright: translation.copyright };
      cache.set(key, passage);
      return passage;
    },
  };
}
