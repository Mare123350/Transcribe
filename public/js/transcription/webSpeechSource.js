// The browser's built-in speech recognition. It needs no API key, but the browser always uses the
// system default microphone, and Chrome sends the audio to Google to transcribe it.
const Recognition = globalThis.SpeechRecognition ?? globalThis.webkitSpeechRecognition;

export const isWebSpeechSupported = () => Boolean(Recognition);

const FATAL_ERRORS = {
  'not-allowed': 'Microphone access was blocked. Allow it from the icon in the address bar, then press Start again.',
  'service-not-allowed': 'This browser has speech recognition turned off.',
  'audio-capture': 'No microphone was found. Check the system default input.',
  'language-not-supported': 'This browser cannot recognize the configured language.',
};

export class WebSpeechSource {
  constructor({ onTranscript, onStatus, language = 'en' }) {
    // Browsers want a regional code here, while Deepgram also accepts a plain "en".
    Object.assign(this, { onTranscript, onStatus, language: language.includes('-') ? language : 'en-US' });
    this.active = false;
    this.failures = 0;
  }

  async start() {
    this.active = true;
    this.paused = false;
    this.onStatus({ state: 'requesting', message: 'Waiting for microphone permission…' });
    this.begin();
  }

  begin() {
    const recognition = new Recognition();
    recognition.continuous = true;
    recognition.interimResults = true;
    recognition.lang = this.language;
    this.recognition = recognition;

    recognition.onstart = () => this.onStatus({ state: this.paused ? 'paused' : 'listening' });
    recognition.onresult = (event) => {
      this.failures = 0;
      let interim = '';
      for (let i = event.resultIndex; i < event.results.length; i++) {
        const result = event.results[i];
        if (result.isFinal) this.onTranscript({ text: result[0].transcript, isFinal: true });
        else interim += result[0].transcript;
      }
      if (interim) this.onTranscript({ text: interim, isFinal: false });
    };
    recognition.onerror = (event) => {
      if (event.error === 'no-speech' || event.error === 'aborted') return;
      if (FATAL_ERRORS[event.error]) {
        this.active = false;
        this.onStatus({ state: 'error', message: FATAL_ERRORS[event.error] });
        return;
      }
      this.failures++;
      if (event.error === 'network') {
        this.onStatus({ state: 'reconnecting', message: "Speech recognition can't reach its service. Retrying…" });
      } else {
        this.onStatus({ state: 'reconnecting', message: `Speech recognition error (${event.error}). Retrying…` });
      }
    };
    // Browsers end recognition on their own every so often. Restart it so a sermon keeps going.
    recognition.onend = () => {
      if (!this.active || this.paused) return;
      const delay = Math.min(300 * 2 ** this.failures, 10_000); // back off during an outage
      this.restartTimer = setTimeout(() => this.active && this.begin(), delay);
    };
    recognition.start();
  }

  pause() {
    this.paused = true;
    clearTimeout(this.restartTimer);
    this.recognition?.stop();
    this.onStatus({ state: 'paused' });
  }

  resume() {
    this.paused = false;
    this.begin();
  }

  stop() {
    this.active = false;
    clearTimeout(this.restartTimer);
    this.recognition?.stop();
    this.recognition = null;
  }
}
