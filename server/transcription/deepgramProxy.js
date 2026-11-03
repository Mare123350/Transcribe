import { WebSocket } from 'ws';

// Relays microphone audio from the browser to Deepgram, so the API key never reaches the browser.
//   browser -> server: binary PCM16 at 16 kHz, or JSON { type: 'finalize' | 'stop' }
//   server -> browser: JSON { type: 'transcript', text, isFinal } or { type: 'status', state, code?, message? }
// Close code 4401 tells the browser that retrying won't help (key missing or refused).

export const CLOSE_NO_RETRY = 4401;
const MAX_QUEUED_FRAMES = 50; // about five seconds of audio while the upstream connection opens

export function deepgramListenUrl({ baseUrl = 'wss://api.deepgram.com/v1/listen', model = 'nova-3', language = 'en' } = {}) {
  const params = new URLSearchParams({
    model,
    language,
    encoding: 'linear16',
    sample_rate: '16000',
    channels: '1',
    interim_results: 'true',
    punctuate: 'true',
    endpointing: '300',
    mip_opt_out: 'true', // don't let Deepgram keep this audio for model improvement
  });
  return `${baseUrl}?${params}`;
}

export function handleTranscriptionClient(client, { apiKey, url, keepAliveMs = 4000 }) {
  const status = (state, extra = {}) => {
    if (client.readyState === WebSocket.OPEN) client.send(JSON.stringify({ type: 'status', state, ...extra }));
  };

  if (!apiKey) {
    status('error', { code: 'not_configured', message: 'Deepgram is not configured. Set DEEPGRAM_API_KEY on the server.' });
    client.close(CLOSE_NO_RETRY, 'not configured');
    return;
  }

  const upstream = new WebSocket(url, { headers: { Authorization: `Token ${apiKey}` } });
  const queue = [];
  let lastAudioAt = Date.now();

  // Deepgram closes a stream after 10 seconds with no audio, which is what happens during a pause.
  const keepAlive = setInterval(() => {
    if (upstream.readyState === WebSocket.OPEN && Date.now() - lastAudioAt >= keepAliveMs) {
      upstream.send(JSON.stringify({ type: 'KeepAlive' }));
    }
  }, keepAliveMs);

  const closeUpstream = () => {
    clearInterval(keepAlive);
    if (upstream.readyState === WebSocket.OPEN) {
      upstream.send(JSON.stringify({ type: 'CloseStream' }));
      upstream.close();
    } else if (upstream.readyState === WebSocket.CONNECTING) {
      upstream.terminate();
    }
  };

  upstream.on('open', () => {
    for (const frame of queue.splice(0)) upstream.send(frame);
    status('connected');
  });

  upstream.on('message', (data, isBinary) => {
    if (isBinary || client.readyState !== WebSocket.OPEN) return;
    let message;
    try {
      message = JSON.parse(data.toString());
    } catch {
      return;
    }
    if (message.type !== 'Results') return;
    const text = message.channel?.alternatives?.[0]?.transcript ?? '';
    const isFinal = Boolean(message.is_final);
    if (text || isFinal) client.send(JSON.stringify({ type: 'transcript', text, isFinal }));
  });

  upstream.on('unexpected-response', (_request, response) => {
    response.resume();
    clearInterval(keepAlive);
    const refused = response.statusCode === 401 || response.statusCode === 402 || response.statusCode === 403;
    const message = refused
      ? `Deepgram refused the connection (HTTP ${response.statusCode}). Check the API key and account balance.`
      : `Deepgram couldn't start transcription (HTTP ${response.statusCode}).`;
    status('error', { code: refused ? 'refused' : 'upstream', message });
    if (client.readyState === WebSocket.OPEN) client.close(refused ? CLOSE_NO_RETRY : 1011, 'upstream refused');
    upstream.terminate();
  });

  upstream.on('error', () => {
    clearInterval(keepAlive);
    status('error', { code: 'upstream', message: "Couldn't reach Deepgram. Check the internet connection." });
    if (client.readyState === WebSocket.OPEN) client.close(1011, 'upstream error');
  });

  upstream.on('close', () => {
    clearInterval(keepAlive);
    if (client.readyState === WebSocket.OPEN) client.close(1011, 'upstream closed');
  });

  client.on('message', (data, isBinary) => {
    if (isBinary) {
      lastAudioAt = Date.now();
      if (upstream.readyState === WebSocket.OPEN) upstream.send(data);
      else if (upstream.readyState === WebSocket.CONNECTING && queue.length < MAX_QUEUED_FRAMES) queue.push(data);
      return;
    }
    let control;
    try {
      control = JSON.parse(data.toString());
    } catch {
      return;
    }
    if (control.type === 'finalize' && upstream.readyState === WebSocket.OPEN) {
      upstream.send(JSON.stringify({ type: 'Finalize' }));
    } else if (control.type === 'stop') {
      closeUpstream();
    }
  });

  client.on('close', closeUpstream);
  client.on('error', closeUpstream);
}
