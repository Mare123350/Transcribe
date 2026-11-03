import { CANONICAL_VERSIFICATION } from '../shared/versification.js';
import { ReferenceDetector } from '../shared/detector.js';

export const KJV = { exact: true, books: CANONICAL_VERSIFICATION };

// A detector on a hand-cranked clock, so timing tests are exact rather than flaky.
export function harness(options = {}) {
  const log = { detections: [], repeats: [], tentative: [] };
  let time = 0;
  let timers = [];
  const detector = new ReferenceDetector({
    versification: KJV,
    onDetection: (d) => log.detections.push(d),
    onRepeat: (d) => log.repeats.push(d),
    onTentative: (t) => log.tentative.push(t),
    now: () => time,
    setTimer: (fn, ms) => { const timer = { fn, at: time + ms }; timers.push(timer); return timer; },
    clearTimer: (timer) => { timers = timers.filter((t) => t !== timer); },
    ...options,
  });
  return {
    detector,
    log,
    keys: () => log.detections.map((d) => d.key),
    advance(ms) {
      time += ms;
      for (const timer of timers.filter((t) => t.at <= time)) {
        timers = timers.filter((t) => t !== timer);
        timer.fn();
      }
    },
  };
}

// Feeds lines as final segments and lets everything settle. Returns the detections.
export function detect(...lines) {
  const h = harness();
  for (const line of lines) {
    h.detector.addFinal(line);
    h.advance(100);
  }
  h.advance(5_000);
  return h.log.detections;
}
