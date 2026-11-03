// Captures the selected input and streams it to our server, which relays it to Deepgram.
// All sources share one shape: start/pause/resume/stop, plus onTranscript and onStatus callbacks.
const RETRY_DELAYS = [1000, 2000, 4000, 8000, 15000];
const CLOSE_NO_RETRY = 4401;

export class DeepgramSource {
  constructor({ onTranscript, onStatus, onLevel }) {
    Object.assign(this, { onTranscript, onStatus, onLevel });
    this.active = false;
    this.paused = false;
  }

  async start({ deviceId }) {
    // Stop can be pressed while the permission prompt is still up. `run` lets this notice when it
    // resumes, so the microphone doesn't turn on after the screen says it has stopped.
    const run = {};
    this.run = run;
    this.onStatus({ state: 'requesting', message: 'Waiting for microphone permission…' });
    const stream = await navigator.mediaDevices.getUserMedia({
      audio: {
        deviceId: deviceId ? { exact: deviceId } : undefined,
        channelCount: 1,
        echoCancellation: false,
        noiseSuppression: true,
        autoGainControl: true,
      },
    });
    if (this.run !== run) {
      for (const track of stream.getTracks()) track.stop();
      return;
    }
    this.stream = stream;
    this.audio = new AudioContext();
    await this.audio.audioWorklet.addModule('/js/transcription/pcm-worklet.js');
    if (this.run !== run) return;
    const input = this.audio.createMediaStreamSource(this.stream);
    this.worklet = new AudioWorkletNode(this.audio, 'pcm-processor');
    this.worklet.port.onmessage = ({ data }) => {
      this.onLevel?.(this.paused ? 0 : data.level);
      if (!this.paused && this.socket?.readyState === WebSocket.OPEN) this.socket.send(data.samples);
    };
    input.connect(this.worklet);
    this.active = true;
    this.paused = false;
    this.attempt = 0;
    this.connect();
  }

  connect() {
    const protocol = location.protocol === 'https:' ? 'wss:' : 'ws:';
    const socket = new WebSocket(`${protocol}//${location.host}/ws/transcribe`);
    socket.binaryType = 'arraybuffer';
    this.socket = socket;
    this.lastError = null;

    socket.addEventListener('message', (event) => {
      const message = JSON.parse(event.data);
      if (message.type === 'transcript') {
        this.onTranscript({ text: message.text, isFinal: message.isFinal });
      } else if (message.type === 'status') {
        if (message.state === 'connected') {
          this.attempt = 0;
          this.onStatus({ state: this.paused ? 'paused' : 'listening' });
        } else if (message.state === 'error') {
          this.lastError = message.message;
        }
      }
    });

    socket.addEventListener('close', (event) => {
      if (!this.active || socket !== this.socket) return;
      if (event.code === CLOSE_NO_RETRY) {
        this.onStatus({ state: 'error', message: this.lastError ?? 'Transcription was refused.' });
        this.stop();
        return;
      }
      const delay = RETRY_DELAYS[Math.min(this.attempt++, RETRY_DELAYS.length - 1)];
      this.onStatus({
        state: 'reconnecting',
        message: `${this.lastError ?? 'Lost the transcription connection.'} Retrying in ${delay / 1000}s…`,
      });
      this.retryTimer = setTimeout(() => this.connect(), delay);
    });
  }

  pause() {
    this.paused = true;
    if (this.stream) for (const track of this.stream.getTracks()) track.enabled = false;
    if (this.socket?.readyState === WebSocket.OPEN) this.socket.send(JSON.stringify({ type: 'finalize' }));
    this.onStatus({ state: 'paused' });
  }

  resume() {
    this.paused = false;
    if (this.stream) for (const track of this.stream.getTracks()) track.enabled = true;
    this.onStatus({ state: this.socket?.readyState === WebSocket.OPEN ? 'listening' : 'reconnecting' });
  }

  stop() {
    this.run = null;
    this.active = false;
    clearTimeout(this.retryTimer);
    if (this.socket?.readyState === WebSocket.OPEN) this.socket.send(JSON.stringify({ type: 'stop' }));
    this.socket?.close();
    this.socket = null;
    this.worklet?.disconnect();
    this.audio?.close();
    this.audio = null;
    // Stopping the tracks is what turns off the browser's recording indicator.
    if (this.stream) for (const track of this.stream.getTracks()) track.stop();
    this.stream = null;
    this.onLevel?.(0);
  }
}
