// Plays a sample sermon through the real pipeline, word by word, the way a speech engine reports it.
// No microphone and no network; the labelled demo mode uses this in place of real transcription.
const WORD_MS = 170;
const LINE_GAP_MS = 500;

export class DemoSource {
  constructor({ onTranscript, onStatus, onFinished, transcript, speed = 1 }) {
    Object.assign(this, { onTranscript, onStatus, onFinished, transcript, speed });
    this.line = 0;
    this.word = 0;
    this.active = false;
    this.paused = false;
  }

  async start() {
    this.active = true;
    this.paused = false;
    this.onStatus({ state: 'listening' });
    this.schedule(200);
  }

  schedule(ms) {
    this.timer = setTimeout(() => this.step(), ms / this.speed);
  }

  step() {
    if (!this.active || this.paused) return;
    const line = this.transcript.lines[this.line];
    if (!line) {
      this.onFinished?.();
      return;
    }
    const words = line.say.split(' ');
    this.word++;
    if (this.word < words.length) {
      this.onTranscript({ text: words.slice(0, this.word).join(' '), isFinal: false });
      this.schedule(WORD_MS);
    } else {
      this.onTranscript({ text: line.say, isFinal: true });
      this.line++;
      this.word = 0;
      this.schedule(line.pause ?? LINE_GAP_MS);
    }
  }

  pause() {
    this.paused = true;
    clearTimeout(this.timer);
    this.onStatus({ state: 'paused' });
  }

  resume() {
    this.paused = false;
    this.onStatus({ state: 'listening' });
    this.schedule(200);
  }

  stop() {
    this.active = false;
    clearTimeout(this.timer);
  }
}
