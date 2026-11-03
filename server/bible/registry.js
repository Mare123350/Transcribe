import { formatRef } from '../../shared/references.js';
import { validateRef } from '../../shared/validate.js';
import { createApiBibleProvider } from './apiBibleProvider.js';
import { BibleError } from './errors.js';
import { createEsvProvider } from './esvProvider.js';
import { createLocalProvider } from './localProvider.js';
import { TRANSLATIONS } from './translations.js';

// Builds a provider for each translation. One without credentials stays listed but is marked
// unavailable, with the reason. A lookup never falls back to a different translation.
export async function createBibleRegistry({ env = process.env, dataDir, fetchImpl = fetch, translations = TRANSLATIONS }) {
  const entries = new Map();

  for (const translation of translations) {
    let provider = null;
    let unavailableReason = null;
    if (translation.source === 'local') {
      provider = await createLocalProvider(translation, dataDir);
    } else if (translation.source === 'api.bible') {
      if (env.API_BIBLE_KEY && env[translation.idEnv]) {
        provider = createApiBibleProvider(translation, { apiKey: env.API_BIBLE_KEY, bibleId: env[translation.idEnv], fetchImpl });
      } else {
        unavailableReason = `Licensed translation. Set API_BIBLE_KEY and ${translation.idEnv} on the server to enable it.`;
      }
    } else if (translation.source === 'esv') {
      if (env.ESV_API_KEY) provider = createEsvProvider(translation, { apiKey: env.ESV_API_KEY, fetchImpl });
      else unavailableReason = 'Licensed translation. Set ESV_API_KEY on the server to enable it.';
    }
    entries.set(translation.id, { translation, provider, unavailableReason });
  }

  const listing = () => [...entries.values()].map(({ translation, provider, unavailableReason }) => ({
    id: translation.id,
    name: translation.name,
    abbreviation: translation.abbreviation,
    available: Boolean(provider),
    unavailableReason,
  }));

  const usable = (id) => {
    const entry = entries.get(id);
    if (!entry) throw new BibleError('unavailable', `Unknown translation “${id}”.`);
    if (!entry.provider) throw new BibleError('unavailable', `${entry.translation.abbreviation} is not available. ${entry.unavailableReason}`);
    return entry;
  };

  return {
    listing,
    versification: (id) => usable(id).provider.versification(),

    async getPassage(ref, id) {
      const { translation, provider } = usable(id);
      const check = validateRef(ref, provider.versification());
      if (!check.ok) throw new BibleError('not_found', check.reason);
      const passage = await provider.getPassage(ref);
      return {
        reference: formatRef(ref),
        translation: { id: translation.id, name: translation.name, abbreviation: translation.abbreviation },
        ...passage,
      };
    },
  };
}
