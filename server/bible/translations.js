// Every translation the app knows about. To add one, add a line here; if it comes through
// API.Bible, that's all the code it needs. See the README for what each source requires.
//
//   local:     bundled public-domain text in data/
//   api.bible: licensed text through API.Bible; `idEnv` names the variable holding its Bible ID
//   esv:       licensed text through Crossway's ESV API
export const TRANSLATIONS = [
  { id: 'kjv', name: 'King James Version', abbreviation: 'KJV', source: 'local', file: 'kjv.json', copyright: 'Public domain in most of the world. Crown copyright applies in the UK.' },
  { id: 'web', name: 'World English Bible', abbreviation: 'WEB', source: 'local', file: 'web.json', copyright: 'Public domain.' },
  { id: 'nkjv', name: 'New King James Version', abbreviation: 'NKJV', source: 'api.bible', idEnv: 'API_BIBLE_ID_NKJV' },
  { id: 'niv', name: 'New International Version', abbreviation: 'NIV', source: 'api.bible', idEnv: 'API_BIBLE_ID_NIV' },
  { id: 'esv', name: 'English Standard Version', abbreviation: 'ESV', source: 'esv', copyright: 'ESV® Bible © 2001 by Crossway. Used by permission.' },
  { id: 'nlt', name: 'New Living Translation', abbreviation: 'NLT', source: 'api.bible', idEnv: 'API_BIBLE_ID_NLT' },
  { id: 'nasb', name: 'New American Standard Bible', abbreviation: 'NASB', source: 'api.bible', idEnv: 'API_BIBLE_ID_NASB' },
  { id: 'nrsv', name: 'New Revised Standard Version', abbreviation: 'NRSV', source: 'api.bible', idEnv: 'API_BIBLE_ID_NRSV' },
];
