// The song model, and turning pasted text or OpenLyrics files into it.
//   { id, title, artist, language, ccli, order: ['v1', 'c', ...],
//     sections: [{ id: 'v1', type: 'verse', label: 'Verse 1', lines: ['...'] }] }

const SECTION_TYPES = [
  { type: 'verse', id: 'v', label: 'Verse', names: ['verse', 'v'] },
  { type: 'prechorus', id: 'p', label: 'Pre-Chorus', names: ['pre-chorus', 'prechorus', 'pre chorus', 'p'] },
  { type: 'chorus', id: 'c', label: 'Chorus', names: ['chorus', 'refrain', 'c', 'r'] },
  { type: 'bridge', id: 'b', label: 'Bridge', names: ['bridge', 'b'] },
  { type: 'tag', id: 't', label: 'Tag', names: ['tag', 't'] },
  { type: 'vamp', id: 'vamp', label: 'Vamp', names: ['vamp', 'hook'] },
  { type: 'intro', id: 'i', label: 'Intro', names: ['intro'] },
  { type: 'outro', id: 'o', label: 'Outro', names: ['outro', 'ending', 'end'] },
];
const TYPE_BY_NAME = new Map(SECTION_TYPES.flatMap((t) => t.names.map((name) => [name, t])));

// "[Chorus 2]", "Verse 1:", "V1", "Pre-Chorus"
const LABEL_RE = /^\[?\s*(pre[- ]?chorus|verse|chorus|refrain|bridge|tag|vamp|hook|intro|outro|ending|end|[vcbprt])\s*(\d+)?\s*\]?\s*:?$/i;

function parseLabel(line) {
  const match = LABEL_RE.exec(line.trim());
  if (!match) return null;
  // A lone letter only counts as a label with a number, or in brackets: "A" could be a lyric.
  const word = match[1].toLowerCase();
  if (word.length === 1 && !match[2] && !line.includes('[')) return null;
  const type = TYPE_BY_NAME.get(word);
  const number = match[2] ? Number(match[2]) : null;
  return {
    id: `${type.id}${number ?? ''}`,
    type: type.type,
    label: number ? `${type.label} ${number}` : type.label,
  };
}

const HEADER_RE = /^(title|artist|author|language|ccli|ccli number|order)\s*:\s*(.*)$/i;

// Reads pasted lyrics. Section labels are optional; unlabelled blocks become numbered verses.
// A label with no lines ("[Chorus]" for the second time) is a repeat, and only adds to the order.
export function parsePlainTextSong(text) {
  const song = { title: '', artist: '', language: 'en', ccli: '', order: [], sections: [] };
  const byId = new Map();
  let explicitOrder = null;
  let current = null;
  let unlabelled = 0;

  const close = () => {
    if (!current) return;
    if (current.lines.length) {
      const existing = byId.get(current.id);
      if (existing) {
        // The same label again with its words retyped: keep the first copy, as a repeat.
      } else {
        byId.set(current.id, current);
        song.sections.push(current);
      }
    }
    if (current.lines.length || byId.has(current.id)) song.order.push(current.id);
    current = null;
  };

  let inHeader = true;
  for (const rawLine of String(text).replace(/\r\n?/g, '\n').split('\n')) {
    const line = rawLine.trim();
    if (inHeader) {
      const header = HEADER_RE.exec(line);
      if (header) {
        const key = header[1].toLowerCase();
        const value = header[2].trim();
        if (key === 'title') song.title = value;
        else if (key === 'artist' || key === 'author') song.artist = value;
        else if (key === 'language') song.language = value;
        else if (key.startsWith('ccli')) song.ccli = value;
        else if (key === 'order') explicitOrder = value.split(/[\s,]+/).filter(Boolean).map((id) => id.toLowerCase());
        continue;
      }
      if (line) inHeader = false;
    }
    const label = parseLabel(line);
    if (label) {
      close();
      current = { ...label, lines: [] };
    } else if (!line) {
      // A blank line ends an unlabelled block, but labelled sections may contain blank lines.
      if (current?.autoLabelled) close();
    } else {
      if (!current) {
        unlabelled++;
        current = { id: `v${unlabelled}`, type: 'verse', label: `Verse ${unlabelled}`, lines: [], autoLabelled: true };
      }
      current.lines.push(line);
    }
  }
  close();

  song.sections = song.sections.map(({ autoLabelled, ...section }) => section);
  if (explicitOrder) song.order = explicitOrder;
  return song;
}

export function songToPlainText(song) {
  const header = [
    `Title: ${song.title ?? ''}`,
    `Artist: ${song.artist ?? ''}`,
    `Language: ${song.language ?? 'en'}`,
    `CCLI: ${song.ccli ?? ''}`,
    `Order: ${(song.order ?? []).join(' ')}`,
  ];
  const body = (song.sections ?? []).map((section) => `[${section.label}]\n${section.lines.join('\n')}`);
  return `${header.join('\n')}\n\n${body.join('\n\n')}\n`;
}

const decodeEntities = (text) => text
  .replace(/&#(\d+);/g, (_, code) => String.fromCodePoint(Number(code)))
  .replace(/&#x([0-9a-f]+);/gi, (_, code) => String.fromCodePoint(parseInt(code, 16)))
  .replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"').replace(/&apos;/g, "'")
  .replace(/&amp;/g, '&');

const firstTag = (xml, tag) => new RegExp(`<${tag}(?:\\s[^>]*)?>([\\s\\S]*?)</${tag}>`, 'i').exec(xml)?.[1];

// OpenLyrics (openlyrics.org) is a small, regular XML format, so it doesn't need an XML library.
export function parseOpenLyrics(xml) {
  const source = String(xml).replace(/<!--[\s\S]*?-->/g, '');
  if (!/<song[\s>]/i.test(source) || !/<lyrics[\s>]/i.test(source)) {
    throw new Error("This doesn't look like an OpenLyrics file.");
  }
  const clean = (value) => decodeEntities((value ?? '').trim());
  const authors = [...source.matchAll(/<author(?:\s[^>]*)?>([\s\S]*?)<\/author>/gi)].map((m) => clean(m[1]));
  const lyricsBlock = firstTag(source, 'lyrics') ?? '';

  const song = {
    title: clean(firstTag(source, 'title')),
    artist: authors.join(', '),
    language: /<title[^>]*\slang="([^"]+)"/i.exec(source)?.[1] ?? 'en',
    ccli: clean(firstTag(source, 'ccliNo')),
    order: [],
    sections: [],
  };

  const seen = new Map();
  for (const match of lyricsBlock.matchAll(/<verse\s([^>]*)>([\s\S]*?)<\/verse>/gi)) {
    const name = /name="([^"]+)"/i.exec(match[1])?.[1]?.toLowerCase() ?? `v${song.sections.length + 1}`;
    const lines = [...match[2].matchAll(/<lines(?:\s[^>]*)?>([\s\S]*?)<\/lines>/gi)]
      .flatMap((block) => block[1]
        .replace(/<comment>[\s\S]*?<\/comment>/gi, '')
        .replace(/<chord\b[^>]*\/>/gi, '')
        .split(/<br\s*\/?>/i))
      .map((line) => decodeEntities(line.replace(/<[^>]+>/g, '')).replace(/\s+/g, ' ').trim())
      .filter(Boolean);
    const parsed = /^([a-z]+?)(\d*)[a-z]?$/.exec(name);
    const label = parseLabel(`[${parsed?.[1] ?? name}${parsed?.[2] ? ` ${parsed[2]}` : ''}]`);
    const section = {
      id: name,
      type: label?.type ?? 'verse',
      label: label?.label ?? name.toUpperCase(),
      lines,
    };
    if (!seen.has(name) && lines.length) {
      seen.set(name, section);
      song.sections.push(section);
    }
  }
  const verseOrder = clean(firstTag(source, 'verseOrder')).toLowerCase().split(/\s+/).filter((id) => seen.has(id));
  song.order = verseOrder.length ? verseOrder : song.sections.map((s) => s.id);
  return song;
}

// Returns a list of problems, empty when the song can be saved.
export function validateSong(song) {
  const problems = [];
  if (!song || typeof song !== 'object') return ['Song is missing.'];
  if (!String(song.title ?? '').trim()) problems.push('A title is required.');
  if (!Array.isArray(song.sections) || !song.sections.some((s) => s.lines?.length)) problems.push('The song needs at least one section with lyrics.');
  const ids = new Set((song.sections ?? []).map((s) => s.id));
  for (const id of song.order ?? []) {
    if (!ids.has(id)) problems.push(`The order mentions “${id}”, but no section has that label.`);
  }
  return problems;
}

// Every line in the order it's sung. Sections used twice appear twice.
export function arrangementOf(song) {
  const byId = new Map(song.sections.map((section) => [section.id, section]));
  const order = song.order?.length ? song.order : song.sections.map((section) => section.id);
  const lines = [];
  order.forEach((sectionId, orderIndex) => {
    const section = byId.get(sectionId);
    if (!section) return;
    section.lines.forEach((text, lineIndex) => {
      lines.push({ index: lines.length, orderIndex, sectionId, sectionLabel: section.label, lineIndex, text });
    });
  });
  return lines;
}

// One entry per section in the order, for "jump to" buttons.
export function sectionStops(arrangement) {
  const stops = [];
  for (const line of arrangement) {
    if (line.lineIndex === 0) stops.push({ index: line.index, sectionId: line.sectionId, label: line.sectionLabel });
  }
  return stops;
}

export function creditLine(song, { ccliLicense = '', showCredit = true } = {}) {
  if (!showCredit) return '';
  const parts = [[song.title, song.artist].filter(Boolean).join(' — ')];
  if (song.ccli) parts.push(`CCLI Song # ${song.ccli}`);
  if (ccliLicense) parts.push(`CCLI License # ${ccliLicense}`);
  return parts.filter(Boolean).join(' · ');
}

// What's on screen for a position in a song: the current line, and the next one when there's room.
export function lyricsScreen(song, arrangement, index, settings = {}) {
  const current = arrangement[index];
  const next = (settings.linesPerScreen ?? 2) > 1 ? arrangement[index + 1] : null;
  return {
    kind: 'lyrics',
    blank: false,
    lines: [
      { text: current?.text ?? '', current: true },
      ...(next ? [{ text: next.text, current: false }] : []),
    ],
    highlight: settings.highlightCurrent !== false,
    credit: creditLine(song, settings),
  };
}

export function matchesSearch(song, query) {
  const needle = query.trim().toLowerCase();
  if (!needle) return true;
  const haystack = [song.title, song.artist, song.ccli, ...song.sections.flatMap((s) => s.lines)].join(' ').toLowerCase();
  return needle.split(/\s+/).every((word) => haystack.includes(word));
}
