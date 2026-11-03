// Runs on the audio thread. Downsamples the microphone to 16 kHz mono PCM16 and posts 100 ms chunks,
// along with a loudness level for the input meter.
const TARGET_RATE = 16000;
const CHUNK_SAMPLES = 1600;

class PcmProcessor extends AudioWorkletProcessor {
  constructor() {
    super();
    this.ratio = sampleRate / TARGET_RATE;
    this.position = 0;
    this.sum = 0;
    this.count = 0;
    this.chunk = new Int16Array(CHUNK_SAMPLES);
    this.filled = 0;
    this.peak = 0;
  }

  process(inputs) {
    const channel = inputs[0]?.[0];
    if (!channel) return true;
    for (const sample of channel) {
      this.sum += sample;
      this.count++;
      this.position++;
      if (this.position >= this.ratio) {
        this.position -= this.ratio;
        const value = Math.max(-1, Math.min(1, this.sum / this.count));
        this.sum = 0;
        this.count = 0;
        this.peak = Math.max(this.peak, Math.abs(value));
        this.chunk[this.filled++] = value < 0 ? value * 0x8000 : value * 0x7fff;
        if (this.filled === CHUNK_SAMPLES) {
          const samples = this.chunk.slice().buffer;
          this.port.postMessage({ samples, level: this.peak }, [samples]);
          this.filled = 0;
          this.peak = 0;
        }
      }
    }
    return true;
  }
}

registerProcessor('pcm-processor', PcmProcessor);
