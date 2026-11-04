// Which detectors listen in each service mode, and what a Bible reference means during worship.
export const SERVICE_MODES = ['sermon', 'worship', 'auto'];

// `current` is what Auto-detect currently believes is happening.
export function routeFor(mode, current = 'sermon') {
  if (mode === 'sermon') return { verses: true, lyrics: false, activity: 'sermon' };
  if (mode === 'worship') return { verses: true, lyrics: true, activity: 'worship' };
  return { verses: true, lyrics: true, activity: current };
}

// Sorts a Bible reference heard during worship:
//   'lyric':  the words are part of a song, so it's ignored
//   'noise':  too uncertain to bother the operator with during music
//   'aside':  someone mentioned a verse; offer it, but never show it automatically
export function classifyWorshipReference(detection, { isLyric }) {
  if (detection.status === 'invalid') return 'noise';
  if (isLyric(detection.phrase)) return 'lyric';
  const choiceOfBooks = detection.status === 'suggestion' && detection.refs.length > 1;
  if (detection.status !== 'confirmed' && !choiceOfBooks) return 'noise';
  return 'aside';
}
