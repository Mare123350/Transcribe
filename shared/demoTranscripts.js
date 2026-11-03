// Sample sermons for demo mode. Each line is what the "speech engine" finalizes as one segment, so a
// reference split across lines exercises the same logic a real split would. `pause` is milliseconds of
// silence after the line.
export const DEMO_TRANSCRIPTS = [
  {
    id: 'sermon',
    title: 'Sunday sermon',
    description: 'Natural references in the five spoken forms.',
    lines: [
      { say: 'Good morning church, it is so good to be in the house of the Lord today.' },
      { say: 'Let us begin in a very familiar place, John three sixteen.', pause: 1800 },
      { say: 'For God so loved the world, what a powerful statement that is.' },
      { say: 'Now Paul helps us see what that love looks like.' },
      { say: 'Turn with me to First Corinthians thirteen, verses four to seven.', pause: 1800 },
      { say: 'Love is patient, love is kind, and that is how God loves you.' },
      { say: 'And we know that all things work together, Romans eight twenty-eight.', pause: 1800 },
      { say: 'Even in the valley He is with you, so let us read Psalm twenty-three.', pause: 1800 },
      { say: 'The Lord is my shepherd, church, you shall not want.' },
      { say: 'Going back to the gospel for a moment, John chapter three, verse sixteen.', pause: 1500 },
      { say: 'Let us pray.' },
    ],
  },
  {
    id: 'tricky',
    title: 'Tricky cases',
    description: 'Split segments, repeats, mishearings, and references that do not exist.',
    lines: [
      { say: 'Here is a reference split across two segments. Please turn to Romans', pause: 300 },
      { say: 'eight twenty eight, and notice the promise.', pause: 800 },
      { say: 'I will say it again, Romans eight twenty eight. Romans eight twenty eight.', pause: 800 },
      { say: 'Peter denied the Lord, and John three times ran to the tomb, or so a man might say.', pause: 800 },
      { say: 'Paul writes in Corinthians thirteen that love never fails.', pause: 1800 },
      { say: 'And he told the church in Philippines four thirteen that he could do all things.', pause: 1800 },
      { say: 'Some of you are looking for John thirty five, and that chapter does not exist.', pause: 800 },
      { say: 'Others want Psalm one hundred and fifty one, and that is not in our Bible either.', pause: 800 },
      { say: 'Let us go to John three sixteen.', pause: 1800 },
      { say: 'And now look down at verse seventeen.', pause: 1800 },
      { say: 'Paul also says this in Mark two.', pause: 1500 },
    ],
  },
  {
    id: 'long',
    title: 'Long passage',
    description: 'A very long chapter, to try pagination and font sizes.',
    lines: [
      { say: 'This morning we are going to walk through the longest chapter in the Bible.' },
      { say: 'It is Psalm one nineteen.', pause: 2000 },
      { say: 'And the shortest chapter is right next door, Psalm one seventeen.', pause: 2000 },
      { say: 'Then there is the third chapter of Lamentations, verses twenty two to twenty three.', pause: 2000 },
    ],
  },
];
