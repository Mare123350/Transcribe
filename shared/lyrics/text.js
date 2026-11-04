// Text handling for lyric matching: normalization, sound-alike comparison, and removing the kinds of
// errors speech engines make on music. Lyrics and transcripts both go through normalizeWords, so
// spelling choices on either side stop mattering.

const CONTRACTIONS = new Map(Object.entries({
  "i'm": 'i am', "you're": 'you are', "we're": 'we are', "they're": 'they are', "he's": 'he is', "she's": 'she is',
  "it's": 'it is', "that's": 'that is', "there's": 'there is', "here's": 'here is', "what's": 'what is', "who's": 'who is',
  "let's": 'let us', "i've": 'i have', "we've": 'we have', "you've": 'you have', "they've": 'they have',
  "i'll": 'i will', "you'll": 'you will', "we'll": 'we will', "they'll": 'they will', "he'll": 'he will', "she'll": 'she will',
  "i'd": 'i would', "we'd": 'we would', "you'd": 'you would', "they'd": 'they would',
  "won't": 'will not', "can't": 'can not', cannot: 'can not', "don't": 'do not', "doesn't": 'does not', "didn't": 'did not',
  "isn't": 'is not', "aren't": 'are not', "wasn't": 'was not', "weren't": 'were not', "shouldn't": 'should not',
  "wouldn't": 'would not', "couldn't": 'could not', "ain't": 'is not', "o'er": 'over', "e'er": 'ever', "ne'er": 'never',
  "'tis": 'it is', "'twas": 'it was', "'cause": 'because', cuz: 'because', cos: 'because',
  gonna: 'going to', wanna: 'want to', gotta: 'got to', lemme: 'let me', gimme: 'give me',
  alleluia: 'hallelujah', halleluia: 'hallelujah', hallelujia: 'hallelujah', hosana: 'hosanna',
}));

const FILLERS = new Set(['oh', 'o', 'ooh', 'oooh', 'ohh', 'ah', 'aah', 'ahh', 'uh', 'um', 'umm', 'uhh', 'yeah', 'yeh', 'hey', 'mm', 'mmm', 'hmm', 'whoa', 'woah', 'wo', 'na', 'la']);

const ONES = ['zero', 'one', 'two', 'three', 'four', 'five', 'six', 'seven', 'eight', 'nine', 'ten', 'eleven', 'twelve', 'thirteen', 'fourteen', 'fifteen', 'sixteen', 'seventeen', 'eighteen', 'nineteen'];
const TENS = ['', '', 'twenty', 'thirty', 'forty', 'fifty', 'sixty', 'seventy', 'eighty', 'ninety'];

function numberWords(n) {
  if (n < 20) return [ONES[n]];
  if (n < 100) return n % 10 ? [TENS[Math.floor(n / 10)], ONES[n % 10]] : [TENS[n / 10]];
  if (n < 1000) return [ONES[Math.floor(n / 100)], 'hundred', ...(n % 100 ? numberWords(n % 100) : [])];
  return [String(n)];
}

// "O'er the hills, we're singin'!" -> ["over", "the", "hills", "we", "are", "singing"]
export function normalizeWords(text) {
  const words = [];
  const raw = String(text).toLowerCase().replace(/[’‘`]/g, "'").match(/[\p{L}\p{N}']+/gu) ?? [];
  for (const piece of raw) {
    const word = piece.replace(/^'+(?!tis|twas|cause)|'+$/g, (match, offset) => (offset > 0 && piece.endsWith("in'") ? 'g' : ''));
    const expanded = CONTRACTIONS.get(word);
    const parts = expanded ? expanded.split(' ') : [word.replace(/'s$/, '').replace(/'/g, '')];
    for (const part of parts) {
      if (!part || FILLERS.has(part)) continue;
      if (/^\d+$/.test(part)) words.push(...numberWords(Number(part)));
      else words.push(part);
    }
  }
  return words;
}

// A rough sound-alike key, so "lord" and "laud" or "grace" and "graze" sit near each other.
export function phoneticKey(word) {
  const consonants = word
    .replace(/ph/g, 'f').replace(/gh/g, '').replace(/ck/g, 'k').replace(/c(?=[eiy])/g, 's').replace(/c/g, 'k')
    .replace(/q/g, 'k').replace(/x/g, 'ks').replace(/z/g, 's').replace(/^wr/, 'r').replace(/^kn/, 'n').replace(/mb$/, 'm').replace(/dg/g, 'j');
  const body = consonants.slice(1).replace(/[aeiouyhw]/g, '');
  return (consonants[0] + body).replace(/(.)\1+/g, '$1');
}

function editDistance(a, b) {
  let previous = Array.from({ length: b.length + 1 }, (_, i) => i);
  for (let i = 1; i <= a.length; i++) {
    const current = [i];
    for (let j = 1; j <= b.length; j++) {
      current[j] = Math.min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] === b[j - 1] ? 0 : 1));
    }
    previous = current;
  }
  return previous[b.length];
}

const similarityCache = new Map();

// 1 for the same word, less for near misses, 0 for different words.
export function wordSimilarity(a, b) {
  if (a === b) return 1;
  const key = a < b ? `${a}|${b}` : `${b}|${a}`;
  const cached = similarityCache.get(key);
  if (cached !== undefined) return cached;
  let score = 0;
  const longest = Math.max(a.length, b.length);
  if (a.length >= 3 && b.length >= 3 && Math.abs(a.length - b.length) <= 2 && phoneticKey(a) === phoneticKey(b)) score = 0.85;
  if (!score && longest >= 4) {
    const closeness = 1 - editDistance(a, b) / longest;
    if (closeness >= 0.7) score = closeness;
  }
  if (similarityCache.size > 100_000) similarityCache.clear();
  similarityCache.set(key, score);
  return score;
}

// Finds the best stretch of `heard` that sings `line`, tolerating wrong, missing and extra words.
//   line: [{ word, weight }]    heard: [word, ...]
// Returns { coverage, words, start, end }: coverage is the share of the line's weight heard.
export function alignLine(line, heard, gapPenalty = 0.08) {
  const totalWeight = line.reduce((sum, item) => sum + item.weight, 0) || 1;
  const width = heard.length + 1;
  const blank = { score: 0, matched: 0, words: 0, start: -1 };
  let previous = Array(width).fill(blank);
  let best = blank;
  let bestEnd = -1;

  for (const { word, weight } of line) {
    const current = [blank];
    for (let j = 1; j < width; j++) {
      const similarity = wordSimilarity(word, heard[j - 1]);
      let cell = blank;
      if (previous[j].score > cell.score) cell = previous[j]; // a line word wasn't heard
      const skip = current[j - 1];
      if (skip.score - gapPenalty * weight > cell.score) { // an extra word was heard
        cell = { ...skip, score: skip.score - gapPenalty * weight };
      }
      if (similarity) {
        const before = previous[j - 1];
        const score = before.score + similarity * weight;
        if (score > cell.score) {
          cell = {
            score,
            matched: before.matched + similarity * weight,
            words: before.words + 1,
            start: before.start < 0 ? j - 1 : before.start,
            end: j - 1,
          };
        }
      }
      current[j] = cell;
      if (cell.score > best.score) {
        best = cell;
        bestEnd = cell.end;
      }
    }
    previous = current;
  }
  return { coverage: best.matched / totalWeight, words: best.words, start: best.start, end: bestEnd };
}

const STANDALONE_NOISE = new Set(['music', 'applause', 'silence', 'singing', 'foreign', 'inaudible', 'instrumental', 'background music', 'music playing']);
const INVENTED_PHRASES = ['thank you for watching', 'thanks for watching', 'please subscribe', 'subscribe to my channel', 'like and subscribe', 'see you in the next video'];

function collapseLoops(words, maxRepeats) {
  const output = [];
  let i = 0;
  while (i < words.length) {
    let advanced = false;
    for (let size = 1; size <= 6 && i + size * (maxRepeats + 1) <= words.length; size++) {
      const phrase = words.slice(i, i + size).join(' ');
      let repeats = 1;
      while (words.slice(i + size * repeats, i + size * (repeats + 1)).join(' ') === phrase) repeats++;
      if (repeats > maxRepeats) {
        for (let r = 0; r < maxRepeats; r++) output.push(...words.slice(i, i + size));
        i += size * repeats;
        advanced = true;
        break;
      }
    }
    if (!advanced) output.push(words[i++]);
  }
  return output;
}

// Cleans one final transcript result before matching. `words` is the engine's per-word detail when
// it provides one. Only the lyric path uses this: verse detection keeps reading the original text.
export function cleanTranscript(text, { words, minWordConfidence = 0.25, maxPhraseRepeats = 3 } = {}) {
  const source = Array.isArray(words) && words.length
    ? words.filter((word) => (word.confidence ?? 1) >= minWordConfidence).map((word) => word.word).join(' ')
    : String(text);
  let cleaned = source.replace(/[[(][^\])]*[\])]/g, ' ').replace(/[♪♫♩♬]/g, ' ');
  const whole = normalizeWords(cleaned).join(' ');
  if (STANDALONE_NOISE.has(whole)) return [];
  let tokens = normalizeWords(cleaned);
  for (const phrase of INVENTED_PHRASES) {
    const parts = phrase.split(' ');
    for (let i = tokens.length - parts.length; i >= 0; i--) {
      if (parts.every((part, k) => tokens[i + k] === part)) tokens.splice(i, parts.length);
    }
  }
  return collapseLoops(tokens, maxPhraseRepeats);
}
