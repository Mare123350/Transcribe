// Generates the synthetic transcripts in test/fixtures/replay/ from the sample songs. The noise is
// made up (seeded, so files don't change between runs): a stand-in until real choir transcripts exist.
import { mkdirSync, writeFileSync } from 'node:fs';
import { SAMPLE_SONGS } from '../shared/lyrics/sampleSongs.js';

const out = new URL('../test/fixtures/replay/', import.meta.url).pathname;
mkdirSync(out, { recursive: true });

const SOUND_ALIKES = {
  lantern: 'lanterns', water: 'waters', evening: 'even', tide: 'tied', window: 'widow', harbor: 'harper', glowing: 'going',
  sailors: 'sellers', morning: 'mourning', fog: 'frog', gather: 'gaither', door: 'dour', voices: 'voice', shore: 'sure',
  copper: 'proper', bell: 'belt', river: 'liver', dust: 'dusk', beam: 'bean', wheat: 'weed', clover: 'closer', current: 'currant',
  stream: 'scream', pines: 'pins', moon: 'noon', apples: 'chapels', orchard: 'ordered', breeze: 'please', branch: 'bench',
  blossom: 'blossoms', honey: 'money', hollow: 'hello', cider: 'spider', basket: 'casket', snowfall: 'snow fall',
  roots: 'routes', seeds: 'seats', dandelions: 'dandy lions', swallows: 'swallow', cottage: 'college', dew: 'do',
  kettle: 'cattle', stove: 'stone', story: 'glory', road: 'rode', pebbles: 'people', surf: 'serve', gulls: 'girls',
  pier: 'peer', rope: 'robe', weather: 'whether', anchor: 'anger', thunder: 'under', headland: 'headlines', cabin: 'cable',
  rowing: 'growing',
};

function makeRandom(seed) {
  let state = seed;
  return () => {
    state = (state * 1664525 + 1013904223) % 4294967296;
    return state / 4294967296;
  };
}

function corrupt(line, noise, random) {
  const words = line.split(' ');
  const output = [];
  for (const word of words) {
    const clean = word.toLowerCase().replace(/[^a-z]/g, '');
    if (random() < (noise.drop ?? 0)) continue;
    if (random() < (noise.mishear ?? 0)) {
      output.push(SOUND_ALIKES[clean] ?? (clean.length > 4 ? clean.slice(0, -1) : clean));
    } else {
      output.push(word);
    }
    if (random() < (noise.insert ?? 0)) output.push(['the', 'and', 'oh', 'yeah', 'of'][Math.floor(random() * 5)]);
  }
  return output.join(' ');
}

const LINE_MS = 5000;

function build({ name, setlist = [], noise = {}, seed = 1, script }) {
  const random = makeRandom(seed);
  const byId = new Map(SAMPLE_SONGS.map((song) => [song.id, song]));
  const events = [];
  const truth = [];
  let t = 2000;

  const singLine = (songId, sectionId, line) => {
    const song = byId.get(songId);
    const text = song.sections.find((s) => s.id === sectionId).lines[line];
    const from = t;
    t += LINE_MS;
    truth.push({ from, to: t, song: songId, section: sectionId, line });
    if (random() >= (noise.missLine ?? 0)) events.push({ t: t - 200, final: corrupt(text, noise, random) });
  };

  for (const step of script) {
    if (step.sing) {
      const song = byId.get(step.sing);
      for (const sectionId of step.order ?? song.order) {
        song.sections.find((s) => s.id === sectionId).lines.forEach((_, line) => singLine(step.sing, sectionId, line));
      }
    } else if (step.vamp) {
      for (let i = 0; i < step.times; i++) singLine(step.vamp, step.section, step.line);
    } else if (step.say) {
      const from = t;
      for (const sentence of step.say) {
        t += Math.max(2000, sentence.split(' ').length * 400);
        events.push({ t, final: sentence });
      }
      truth.push({ from, to: t, song: null });
    } else if (step.silence) {
      truth.push({ from: t, to: t + step.silence, song: null });
      t += step.silence;
    }
  }
  writeFileSync(`${out}${name}.json`, `${JSON.stringify({ name, setlist, events, truth }, null, 1)}\n`);
}

const ALL = ['sample-lantern', 'sample-orchard', 'sample-meadow', 'sample-tide'];
const HEAVY = { mishear: 0.2, drop: 0.08, insert: 0.05, missLine: 0.15 };
const TALK = [
  'Good morning church it is so wonderful to be together in the house of the Lord today',
  'Would you please open your Bibles with me as we look at the passage this morning',
  'I want you to think about what it really means to trust when everything feels uncertain',
  'When I was a young man my grandfather used to tell me a story about his first job',
  'He said that you can always tell the character of a person by how they treat a stranger',
  'And that is exactly what the apostle is trying to help this young church understand',
  'They were afraid and they had every reason to be afraid because of what was happening around them',
  'But the message comes to them and it says do not lose heart because you are not alone',
  'So this morning I want to ask you a very simple question and I want you to be honest',
  'What are you holding onto today that you need to finally lay down and walk away from',
  'Some of you came in here carrying something heavy and nobody around you even knows about it',
  'I believe there is hope for you this morning and I believe you are going to leave here different',
  'Now look at how the writer builds this argument one step at a time as we keep on reading',
  'First he reminds them where they came from and then he reminds them who they belong to',
  'That matters because identity shapes every decision you are going to make this coming week',
  'Let me give you an example from something that happened in my own family just last year',
  'My daughter called me very late one night and she was upset about something at her school',
  'And I did not have the right answer but I got in the car and I drove over to see her',
  'Sometimes showing up is the whole sermon and you do not need any clever words at all',
  'Let us think about how that changes the way we treat one another in this congregation',
];

build({ name: 'clean-full-song', setlist: ALL, script: [{ sing: 'sample-lantern' }] });
build({ name: 'noisy-from-setlist', setlist: ALL, noise: HEAVY, seed: 11, script: [{ sing: 'sample-lantern' }] });
build({ name: 'noisy-from-library', setlist: [], noise: HEAVY, seed: 12, script: [{ sing: 'sample-orchard' }] });
build({ name: 'two-songs-with-a-gap', setlist: ALL, noise: { mishear: 0.1, missLine: 0.1 }, seed: 13, script: [{ sing: 'sample-meadow' }, { silence: 12000 }, { sing: 'sample-tide' }] });
build({ name: 'shared-line-only', setlist: [], script: [{ vamp: 'sample-orchard', section: 'c', line: 1, times: 8 }] });
build({ name: 'repeated-choruses', setlist: ALL, noise: { mishear: 0.1 }, seed: 14, script: [{ sing: 'sample-lantern', order: ['v1', 'c', 'c', 'c', 'v2', 'c'] }] });
build({ name: 'skipped-and-out-of-order', setlist: ALL, noise: { mishear: 0.1 }, seed: 15, script: [{ sing: 'sample-lantern', order: ['v2', 'b', 'v1', 'c'] }] });
build({ name: 'vamp-then-move-on', setlist: ALL, seed: 16, script: [{ sing: 'sample-tide', order: ['v1', 'c'] }, { vamp: 'sample-tide', section: 'vamp', line: 0, times: 6 }, { sing: 'sample-tide', order: ['v2', 'c'] }] });
build({ name: 'song-ends-into-talk', setlist: ALL, noise: { mishear: 0.1 }, seed: 17, script: [{ sing: 'sample-meadow' }, { say: TALK }] });
build({ name: 'talk-only', setlist: ALL, script: [{ say: TALK }] });
build({ name: 'worship-then-sermon', setlist: ALL, noise: { mishear: 0.1 }, seed: 18, script: [{ say: TALK.slice(0, 2) }, { sing: 'sample-lantern' }, { say: TALK }] });
build({ name: 'brief-aside-in-song', setlist: ALL, seed: 19, script: [{ sing: 'sample-lantern', order: ['v1', 'c'] }, { say: ['As the psalm reminds us He leads us beside the still waters so sing it again'] }, { sing: 'sample-lantern', order: ['v2', 'c'] }] });
console.log('wrote fixtures to', out);
