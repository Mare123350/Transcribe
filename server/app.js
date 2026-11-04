import { createServer } from 'node:http';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import express from 'express';
import { WebSocketServer } from 'ws';
import { parseRefKey } from '../shared/references.js';
import { createBibleRegistry } from './bible/registry.js';
import { createLyricsRouter } from './lyrics/routes.js';
import { createLyricsStore } from './lyrics/store.js';
import { BibleError } from './bible/errors.js';
import { DisplayHub } from './displayHub.js';
import { deepgramListenUrl, handleTranscriptionClient } from './transcription/deepgramProxy.js';
import { createTranscriptStore } from './transcriptStore.js';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');

const isLoopback = (address = '') => ['127.0.0.1', '::1', '::ffff:127.0.0.1'].includes(address);

const hostnameOf = (hostHeader = '') => hostHeader.replace(/:\d+$/, '').replace(/^\[|\]$/g, '').toLowerCase();

// Rejects requests from other websites. Without this, any page open in the operator's browser could
// talk to this server on localhost, including through DNS rebinding or a cross-site WebSocket.
function isTrustedRequest(request, allowedHosts) {
  const { host, origin } = request.headers;
  if (!allowedHosts.has(hostnameOf(host))) return false;
  if (origin) {
    try {
      return new URL(origin).host === host;
    } catch {
      return false;
    }
  }
  return true;
}

export async function createApp({ env = process.env, fetchImpl = fetch, dataDir = join(root, 'data'), transcriptDir = join(root, 'saved-transcripts'), lyricsDir = env.LYRICS_DIR ?? join(root, 'library'), keepAliveMs } = {}) {
  const bible = await createBibleRegistry({ env, dataDir, fetchImpl });
  const hub = new DisplayHub();
  const transcripts = createTranscriptStore(transcriptDir);
  const lyrics = createLyricsStore(lyricsDir);
  const allowedHosts = new Set(['localhost', '127.0.0.1', '::1', ...(env.ALLOWED_HOSTS ?? '').split(',').map((h) => h.trim().toLowerCase()).filter(Boolean)]);
  const deepgramKey = env.DEEPGRAM_API_KEY;
  const listenUrl = deepgramListenUrl({ baseUrl: env.DEEPGRAM_URL, model: env.DEEPGRAM_MODEL, language: env.TRANSCRIPTION_LANGUAGE });

  const app = express();
  app.disable('x-powered-by');

  app.use((request, response, next) => {
    if (!isTrustedRequest(request, allowedHosts)) return response.status(403).send('Forbidden');
    response.set('Content-Security-Policy', "default-src 'self'; connect-src 'self' ws: wss:; img-src 'self' data:; object-src 'none'; base-uri 'none'; frame-ancestors 'none'");
    response.set('X-Content-Type-Options', 'nosniff');
    next();
  });

  // A projector on another computer only needs the display page. Everything that can control the
  // screen or spend API quota is limited to the operator's own machine.
  const operatorOnly = (request, response, next) => {
    if (isLoopback(request.socket.remoteAddress)) return next();
    response.status(403).json({ error: { code: 'forbidden', message: 'Only available on the operator computer.' } });
  };

  const api = express.Router();
  api.use(operatorOnly);
  api.use(express.json({ limit: '2mb' }));

  api.get('/config', (_request, response) => {
    response.json({
      defaultTranslation: env.DEFAULT_TRANSLATION ?? 'kjv',
      translations: bible.listing(),
      transcription: { deepgram: Boolean(deepgramKey), language: env.TRANSCRIPTION_LANGUAGE ?? 'en' },
      transcriptDirectory: 'saved-transcripts/',
    });
  });

  api.get('/translations/:id/versification', (request, response, next) => {
    try {
      response.json(bible.versification(request.params.id));
    } catch (error) {
      next(error);
    }
  });

  api.get('/passage', async (request, response, next) => {
    const ref = parseRefKey(request.query.ref);
    if (!ref) return response.status(400).json({ error: { code: 'bad_request', message: 'Invalid reference.' } });
    try {
      response.json({ ref, ...(await bible.getPassage(ref, String(request.query.translation ?? ''))) });
    } catch (error) {
      next(error);
    }
  });

  api.post('/display', (request, response) => {
    const state = request.body;
    if (!state || typeof state !== 'object' || Array.isArray(state)) {
      return response.status(400).json({ error: { code: 'bad_request', message: 'Invalid display state.' } });
    }
    response.json({ screens: hub.publish(state) });
  });

  api.post('/transcripts', async (request, response, next) => {
    const text = request.body?.text;
    if (typeof text !== 'string' || !text.trim() || text.length > 20_000) {
      return response.status(400).json({ error: { code: 'bad_request', message: 'Invalid transcript text.' } });
    }
    try {
      await transcripts.append(text);
      response.status(204).end();
    } catch (error) {
      next(error);
    }
  });

  api.use(createLyricsRouter(lyrics));

  api.use((error, _request, response, next) => {
    if (response.headersSent) return next(error);
    if (error instanceof BibleError) {
      const statusCode = { not_found: 404, unavailable: 409, upstream: 502 }[error.code] ?? 500;
      return response.status(statusCode).json({ error: { code: error.code, message: error.message } });
    }
    console.error(error);
    response.status(500).json({ error: { code: 'server', message: 'Something went wrong on the server.' } });
  });

  app.use('/api', api);
  app.get('/', operatorOnly, (_request, response) => response.sendFile(join(root, 'public/operator.html')));
  app.get('/display', (_request, response) => response.sendFile(join(root, 'public/display.html')));
  app.use('/shared', express.static(join(root, 'shared')));
  app.use(express.static(join(root, 'public'), { index: false }));

  const server = createServer(app);
  const displaySockets = new WebSocketServer({ noServer: true });
  const transcribeSockets = new WebSocketServer({ noServer: true, maxPayload: 1024 * 1024 });

  server.on('upgrade', (request, socket, head) => {
    const { pathname, searchParams } = new URL(request.url, 'http://localhost');
    const local = isLoopback(request.socket.remoteAddress);
    const reject = (line) => {
      socket.write(`HTTP/1.1 ${line}\r\nConnection: close\r\n\r\n`);
      socket.destroy();
    };
    if (!isTrustedRequest(request, allowedHosts)) return reject('403 Forbidden');

    if (pathname === '/ws/display') {
      const role = searchParams.get('role') === 'operator' ? 'operator' : 'display';
      if (role === 'operator' && !local) return reject('403 Forbidden');
      displaySockets.handleUpgrade(request, socket, head, (ws) => {
        hub.add(ws, role);
      });
    } else if (pathname === '/ws/transcribe') {
      if (!local) return reject('403 Forbidden');
      transcribeSockets.handleUpgrade(request, socket, head, (ws) => {
        handleTranscriptionClient(ws, { apiKey: deepgramKey, url: listenUrl, keepAliveMs });
      });
    } else {
      reject('404 Not Found');
    }
  });

  const sweeper = setInterval(() => hub.sweep(), 30_000);
  sweeper.unref();
  server.on('close', () => clearInterval(sweeper));

  return { server, hub, bible };
}
