// Clearly fake songs, written for tests and demo mode. No real lyrics belong in this repository;
// a church's own library lives in the gitignored library/ folder.
export const SAMPLE_SONGS = [
  {
    id: 'sample-lantern',
    title: '[Sample] Lantern on the Water',
    artist: 'Demo Choir',
    language: 'en',
    ccli: '',
    sample: true,
    order: ['v1', 'c', 'v2', 'c', 'b', 'c'],
    sections: [
      { id: 'v1', type: 'verse', label: 'Verse 1', lines: ['A lantern drifts across the silver water', 'Carried by the evening tide', 'Every window on the harbor glowing', 'Calling all the sailors home tonight'] },
      { id: 'c', type: 'chorus', label: 'Chorus', lines: ['Sing out across the morning bay', 'Sing until the fog rolls away', 'We will gather by the open door', 'Lifting up our voices on the shore'] },
      { id: 'v2', type: 'verse', label: 'Verse 2', lines: ['A copper bell rings out above the river', 'Shaking dust from every beam', 'Children running through the wheat and clover', 'Following the current of the stream'] },
      { id: 'b', type: 'bridge', label: 'Bridge', lines: ['Higher than the mountain pines', 'Brighter than the harvest moon'] },
    ],
  },
  {
    id: 'sample-orchard',
    title: '[Sample] Orchard of the Morning',
    artist: 'Demo Choir',
    language: 'en',
    ccli: '',
    sample: true,
    order: ['v1', 'c', 'v2', 'c'],
    sections: [
      { id: 'v1', type: 'verse', label: 'Verse 1', lines: ['Golden apples hanging in the orchard', 'Sweetness on the morning breeze', 'Every branch is bending with the blossom', 'Honey in the hollow of the trees'] },
      // The second line here is shared word for word with [Sample] Meadow Song.
      { id: 'c', type: 'chorus', label: 'Chorus', lines: ['Walk with me beneath the arches', 'We will gather by the open door', 'Pour the cider, pass the basket', 'There is always room for more'] },
      { id: 'v2', type: 'verse', label: 'Verse 2', lines: ['Winter sleeping under quilted snowfall', 'Roots remember how to climb', 'Patient seeds beneath the frozen hillside', 'Waiting for the turning of the time'] },
    ],
  },
  {
    id: 'sample-meadow',
    title: '[Sample] Meadow Song',
    artist: 'Demo Choir',
    language: 'en',
    ccli: '',
    sample: true,
    order: ['v1', 'c', 'c'],
    sections: [
      { id: 'v1', type: 'verse', label: 'Verse 1', lines: ['Dandelions dancing in the meadow', 'Swallows wheeling through the blue', 'Barefoot on the path behind the cottage', 'Trampling through the diamonds of the dew'] },
      { id: 'c', type: 'chorus', label: 'Chorus', lines: ['We will gather by the open door', 'Kettle singing on the stove', 'Tell the story one time more', 'Of the road that led us home'] },
    ],
  },
  {
    id: 'sample-tide',
    title: '[Sample] Evening Tide',
    artist: 'Demo Choir',
    language: 'en',
    ccli: '',
    sample: true,
    order: ['v1', 'c', 'v2', 'c', 'vamp'],
    sections: [
      { id: 'v1', type: 'verse', label: 'Verse 1', lines: ['Pebbles rolling in the shallow surf', 'Gulls above the broken pier', 'Fishermen are mending nets at sunset', 'Knowing that the storm is nowhere near'] },
      // These two lines repeat inside the chorus, and the first also returns in verse 2.
      { id: 'c', type: 'chorus', label: 'Chorus', lines: ['Hold the rope and pull together', 'Hold the rope and pull together', 'Steady through the wind and weather', 'Anchor in the harbor deep'] },
      { id: 'v2', type: 'verse', label: 'Verse 2', lines: ['Thunder grumbling past the northern headland', 'Hold the rope and pull together', 'Lamplight trembling on the cabin ceiling', 'Sailors humming softly in their sleep'] },
      { id: 'vamp', type: 'vamp', label: 'Vamp', lines: ['Keep on rowing keep on rowing'] },
    ],
  },
];
