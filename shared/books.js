// The 66-book canon, plus every name a preacher or a speech-to-text engine might use for each book.
// `aliases` are normalized silently. `misheard` are likely transcription errors that are also real
// words or weaker matches, so anything detected through them needs operator confirmation.
// `abbr` are written abbreviations, accepted in the operator's manual search only.

export const BOOKS = [
  { id: 'GEN', name: 'Genesis', aliases: ['genisis', 'jenesis', 'geneses'], abbr: ['gen', 'gn'] },
  { id: 'EXO', name: 'Exodus', aliases: ['exodis', 'exedus'], abbr: ['exo', 'exod', 'ex'] },
  { id: 'LEV', name: 'Leviticus', aliases: ['levitikus', 'leviticous'], abbr: ['lev', 'lv'] },
  { id: 'NUM', name: 'Numbers', commonWord: true, abbr: ['num', 'nm'] },
  { id: 'DEU', name: 'Deuteronomy', aliases: ['duteronomy', 'deutoronomy', 'deuteronomie'], abbr: ['deut', 'deu', 'dt'] },
  { id: 'JOS', name: 'Joshua', commonWord: true, abbr: ['josh', 'jos'] },
  { id: 'JDG', name: 'Judges', commonWord: true, misheard: ['judge'], abbr: ['judg', 'jdg'] },
  { id: 'RUT', name: 'Ruth', commonWord: true, abbr: ['rut', 'ru'] },
  { id: 'EZR', name: 'Ezra', commonWord: true, abbr: ['ezr'] },
  { id: 'NEH', name: 'Nehemiah', aliases: ['nehemia', 'neemiah'], abbr: ['neh'] },
  { id: 'EST', name: 'Esther', commonWord: true, aliases: ['ester'], abbr: ['esth', 'est'] },
  { id: 'JOB', name: 'Job', commonWord: true, abbr: ['jb'] },
  { id: 'PSA', name: 'Psalms', singular: 'Psalm', key: 'psalm', aliases: ['psalms', 'salm', 'salms', 'psalm number', 'psalms number'], misheard: ['sam', 'sams', 'palm', 'palms'], abbr: ['ps', 'psa', 'pss'] },
  { id: 'PRO', name: 'Proverbs', aliases: ['proverb'], abbr: ['prov', 'pro', 'prv'] },
  { id: 'ECC', name: 'Ecclesiastes', aliases: ['ecclesiastics', 'ecclesiasties', 'eclesiastes', 'ecclesiastis'], abbr: ['eccl', 'ecc', 'eccles'] },
  { id: 'SNG', name: 'Song of Solomon', key: 'song of solomon', aliases: ['song of songs', 'songs of solomon', 'song of solomons', 'canticles'], abbr: ['song', 'sos', 'sg'] },
  { id: 'ISA', name: 'Isaiah', aliases: ['isiah', 'isaia', 'isaiahs', 'esaias'], abbr: ['isa', 'is'] },
  { id: 'JER', name: 'Jeremiah', aliases: ['jeramiah', 'jeremia', 'jeremias'], abbr: ['jer'] },
  { id: 'LAM', name: 'Lamentations', aliases: ['lamentation'], abbr: ['lam'] },
  { id: 'EZK', name: 'Ezekiel', aliases: ['ezekial', 'ezeikel', 'ezikiel'], abbr: ['ezek', 'ezk', 'eze'] },
  { id: 'DAN', name: 'Daniel', commonWord: true, abbr: ['dan', 'dn'] },
  { id: 'HOS', name: 'Hosea', commonWord: true, aliases: ['hoseah', 'hosaya'], abbr: ['hos'] },
  { id: 'JOL', name: 'Joel', commonWord: true, abbr: ['jl'] },
  { id: 'AMO', name: 'Amos', commonWord: true, abbr: ['am'] },
  { id: 'OBA', name: 'Obadiah', aliases: ['obediah', 'obadia'], abbr: ['obad', 'ob'] },
  { id: 'JON', name: 'Jonah', commonWord: true, aliases: ['jona'], abbr: ['jnh'] },
  { id: 'MIC', name: 'Micah', commonWord: true, aliases: ['micha', 'mica'], abbr: ['mic', 'mi'] },
  { id: 'NAM', name: 'Nahum', commonWord: true, aliases: ['naham', 'nayhum'], abbr: ['nah', 'na'] },
  { id: 'HAB', name: 'Habakkuk', aliases: ['habakuk', 'habbakuk', 'habacuc', 'habakkuks', 'habbakkuk'], abbr: ['hab'] },
  { id: 'ZEP', name: 'Zephaniah', aliases: ['zefaniah', 'zephania'], abbr: ['zeph', 'zep'] },
  { id: 'HAG', name: 'Haggai', aliases: ['hagai', 'haggi', 'haggay'], abbr: ['hag'] },
  { id: 'ZEC', name: 'Zechariah', aliases: ['zachariah', 'zecharia', 'zacharias', 'zacharia'], abbr: ['zech', 'zec'] },
  { id: 'MAL', name: 'Malachi', aliases: ['malachai', 'malaki', 'malachy'], abbr: ['mal'] },
  { id: 'MAT', name: 'Matthew', commonWord: true, aliases: ['mathew', 'matthews', 'mathews'], abbr: ['matt', 'mat', 'mt'] },
  { id: 'MRK', name: 'Mark', commonWord: true, misheard: ['marks'], abbr: ['mrk', 'mk'] },
  { id: 'LUK', name: 'Luke', commonWord: true, aliases: ['lukes'], abbr: ['luk', 'lk'] },
  { id: 'ACT', name: 'Acts', commonWord: true, aliases: ['acts of the apostles'], misheard: ['act'], abbr: ['ac'] },
  { id: 'ROM', name: 'Romans', misheard: ['roman', 'romance'], abbr: ['rom', 'rm'] },
  { id: 'GAL', name: 'Galatians', aliases: ['galatian', 'galations'], misheard: ['galicians'], abbr: ['gal'] },
  { id: 'EPH', name: 'Ephesians', aliases: ['ephesian', 'ephesions'], abbr: ['eph'] },
  { id: 'PHP', name: 'Philippians', aliases: ['phillipians', 'philipians', 'philippian', 'phillippians'], misheard: ['philippines', 'filipinos', 'philippine'], abbr: ['phil', 'php'] },
  { id: 'COL', name: 'Colossians', aliases: ['colossian', 'collosians', 'colosians'], misheard: ['collisions'], abbr: ['col'] },
  { id: 'TIT', name: 'Titus', commonWord: true, aliases: ['tidus'], abbr: ['tit'] },
  { id: 'PHM', name: 'Philemon', aliases: ['filemon', 'philamon'], abbr: ['phlm', 'phm', 'philem'] },
  { id: 'HEB', name: 'Hebrews', misheard: ['hebrew'], abbr: ['heb'] },
  { id: 'JAS', name: 'James', commonWord: true, abbr: ['jas', 'jms'] },
  { id: 'JUD', name: 'Jude', commonWord: true, abbr: ['jud'] },
  { id: 'REV', name: 'Revelation', aliases: ['revelations', 'revelation of john', 'revelation of saint john'], misheard: ['revolution', 'revolutions'], abbr: ['rev', 'rv'] },
  { id: 'JHN', name: 'John', commonWord: true, aliases: ['jon'], abbr: ['jn', 'jhn'] },

  { id: '1SA', name: '1 Samuel' }, { id: '2SA', name: '2 Samuel' },
  { id: '1KI', name: '1 Kings' }, { id: '2KI', name: '2 Kings' },
  { id: '1CH', name: '1 Chronicles' }, { id: '2CH', name: '2 Chronicles' },
  { id: '1CO', name: '1 Corinthians' }, { id: '2CO', name: '2 Corinthians' },
  { id: '1TH', name: '1 Thessalonians' }, { id: '2TH', name: '2 Thessalonians' },
  { id: '1TI', name: '1 Timothy' }, { id: '2TI', name: '2 Timothy' },
  { id: '1PE', name: '1 Peter' }, { id: '2PE', name: '2 Peter' },
  { id: '1JN', name: '1 John' }, { id: '2JN', name: '2 John' }, { id: '3JN', name: '3 John' },
];

// Books that need a leading number. Said without one ("Corinthians thirteen") they are ambiguous.
// John is the exception: on its own it means the Gospel.
export const NUMBERED_BASES = [
  { key: 'samuel', ids: { 1: '1SA', 2: '2SA' }, aliases: ['samuels'], abbr: ['sam', 'sa'] },
  { key: 'kings', ids: { 1: '1KI', 2: '2KI' }, aliases: [], abbr: ['kgs', 'ki'] },
  { key: 'chronicles', ids: { 1: '1CH', 2: '2CH' }, aliases: ['chronicle'], abbr: ['chron', 'chr', 'ch'] },
  { key: 'corinthians', ids: { 1: '1CO', 2: '2CO' }, aliases: ['corinthian', 'carinthians', 'corinthains', 'corrinthians'], abbr: ['cor', 'co'] },
  { key: 'thessalonians', ids: { 1: '1TH', 2: '2TH' }, aliases: ['thessalonian', 'thessalonica', 'thesalonians'], abbr: ['thess', 'thes', 'th'] },
  { key: 'timothy', ids: { 1: '1TI', 2: '2TI' }, aliases: ['timmothy'], abbr: ['tim', 'ti'] },
  { key: 'peter', ids: { 1: '1PE', 2: '2PE' }, aliases: [], abbr: ['pet', 'pe', 'pt'] },
  { key: 'john', ids: { 1: '1JN', 2: '2JN', 3: '3JN' }, defaultId: 'JHN', aliases: ['jon'], abbr: ['jn', 'jhn'] },
];

export const SINGLE_CHAPTER_BOOKS = new Set(['OBA', 'PHM', '2JN', '3JN', 'JUD']);

const BOOKS_BY_ID = new Map(BOOKS.map((book) => [book.id, book]));

export const bookById = (id) => BOOKS_BY_ID.get(id);

// The name shown on screen. "Psalm 23", but "Psalms" when talking about the book.
export const displayBookName = (id) => {
  const book = bookById(id);
  return book?.singular ?? book?.name ?? id;
};
