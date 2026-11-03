import { isWholeChapter, refKey, formatRef } from '../../shared/references.js';
import { BibleError } from './errors.js';
import { PassageCache, approximateVersification, fetchJson, parseMarkedVerses } from './remoteHelpers.js';

const BASE_URL = 'https://rest.api.bible/v1';

function passageId(ref) {
  const chapter = `${ref.book}.${ref.chapter}`;
  if (isWholeChapter(ref)) return chapter;
  if (ref.verseStart === ref.verseEnd) return `${chapter}.${ref.verseStart}`;
  return `${chapter}.${ref.verseStart}-${chapter}.${ref.verseEnd}`;
}

export function createApiBibleProvider(translation, { apiKey, bibleId, fetchImpl = fetch }) {
  const cache = new PassageCache();
  return {
    available: true,
    versification: () => approximateVersification,
    async getPassage(ref) {
      const key = refKey(ref);
      const cached = cache.get(key);
      if (cached) return cached;

      const params = new URLSearchParams({
        'content-type': 'text',
        'include-notes': 'false',
        'include-titles': 'false',
        'include-chapter-numbers': 'false',
        'include-verse-numbers': 'true',
        'include-verse-spans': 'false',
      });
      const url = `${BASE_URL}/bibles/${encodeURIComponent(bibleId)}/passages/${passageId(ref)}?${params}`;
      let body;
      try {
        body = await fetchJson(fetchImpl, url, { 'api-key': apiKey }, { label: 'API.Bible' });
      } catch (error) {
        if (error.code === 'not_found') throw new BibleError('not_found', `${formatRef(ref)} is not in the ${translation.abbreviation}.`);
        throw error;
      }
      const verses = parseMarkedVerses(body?.data?.content ?? '', ref.verseStart ?? 1);
      if (!verses.length) throw new BibleError('not_found', `${formatRef(ref)} is not in the ${translation.abbreviation}.`);
      const passage = { verses, omitted: [], copyright: body.data.copyright ?? translation.copyright ?? '' };
      cache.set(key, passage);
      return passage;
    },
  };
}
