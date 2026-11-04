import test, { after, before } from 'node:test';
import assert from 'node:assert/strict';
import { once } from 'node:events';
import { createServer } from 'node:http';
import { mkdtemp, readFile, readdir, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { WebSocket, WebSocketServer } from 'ws';
import { createApp } from '../server/app.js';

let app;
let base;
let wsBase;
let fake;
let transcriptDir;
const received = { frames: [], text: [], headers: null, url: null };

// Stands in for Deepgram: accepts or refuses based on the key, and records what arrives.
function startFakeDeepgram() {
  const http = createServer();
  const wss = new WebSocketServer({
    server: http,
    verifyClient: ({ req }, done) => done(req.headers.authorization === 'Token good-key', 401, 'Unauthorized'),
  });
  wss.on('connection', (socket, request) => {
    received.headers = request.headers;
    received.url = request.url;
    socket.on('message', (data, isBinary) => {
      if (isBinary) {
        received.frames.push(data);
        socket.send(JSON.stringify({ type: 'Results', is_final: false, channel: { alternatives: [{ transcript: 'john three' }] } }));
        socket.send(JSON.stringify({ type: 'Results', is_final: true, channel: { alternatives: [{ transcript: 'john three sixteen' }] } }));
        socket.send(JSON.stringify({ type: 'Metadata' }));
      } else {
        received.text.push(JSON.parse(data.toString()));
      }
    });
  });
  return new Promise((resolve) => {
    http.listen(0, '127.0.0.1', () => resolve({ http, wss, url: `ws://127.0.0.1:${http.address().port}/v1/listen` }));
  });
}

async function startApp(env) {
  const instance = await createApp({ env, transcriptDir, keepAliveMs: 40 });
  await new Promise((resolve) => instance.server.listen(0, '127.0.0.1', resolve));
  return { ...instance, port: instance.server.address().port };
}

const stopApp = (instance) => new Promise((resolve) => {
  instance.server.closeAllConnections();
  instance.server.close(resolve);
});

before(async () => {
  transcriptDir = await mkdtemp(join(tmpdir(), 'transcribe-'));
  fake = await startFakeDeepgram();
  app = await startApp({ DEEPGRAM_API_KEY: 'good-key', DEEPGRAM_URL: fake.url });
  base = `http://127.0.0.1:${app.port}`;
  wsBase = `ws://127.0.0.1:${app.port}`;
});

after(async () => {
  await stopApp(app);
  fake.wss.close();
  for (const client of fake.wss.clients) client.terminate();
  fake.http.close();
  await rm(transcriptDir, { recursive: true, force: true });
});

function messagesFrom(socket) {
  const inbox = [];
  const waiting = [];
  socket.on('message', (data) => {
    const message = JSON.parse(data.toString());
    const index = waiting.findIndex((w) => w.test(message));
    if (index >= 0) waiting.splice(index, 1)[0].resolve(message);
    else inbox.push(message);
  });
  return (test) => {
    const index = inbox.findIndex(test);
    if (index >= 0) return Promise.resolve(inbox.splice(index, 1)[0]);
    return new Promise((resolve) => waiting.push({ test, resolve }));
  };
}

test('config exposes translations but no credentials', async () => {
  const response = await fetch(`${base}/api/config`);
  const text = await response.text();
  assert.equal(response.status, 200);
  assert.doesNotMatch(text, /good-key/);
  const config = JSON.parse(text);
  assert.equal(config.transcription.deepgram, true);
  assert.equal(config.translations.find((t) => t.id === 'kjv').available, true);
  assert.equal(config.translations.find((t) => t.id === 'niv').available, false);
});

test('passage endpoint returns scripture and clear errors', async () => {
  const ok = await (await fetch(`${base}/api/passage?ref=JHN.3.16&translation=kjv`)).json();
  assert.equal(ok.reference, 'John 3:16');
  assert.match(ok.verses[0].text, /For God so loved/);

  const missing = await fetch(`${base}/api/passage?ref=JHN.35&translation=kjv`);
  assert.equal(missing.status, 404);
  assert.match((await missing.json()).error.message, /no chapter 35/);

  const locked = await fetch(`${base}/api/passage?ref=JHN.3.16&translation=niv`);
  assert.equal(locked.status, 409);
  assert.equal((await locked.json()).error.code, 'unavailable');

  assert.equal((await fetch(`${base}/api/passage?ref=garbage&translation=kjv`)).status, 400);
});

test('versification endpoint', async () => {
  const table = await (await fetch(`${base}/api/translations/web/versification`)).json();
  assert.equal(table.exact, true);
  assert.equal(table.books.ROM[15], 24);
  assert.equal((await fetch(`${base}/api/translations/niv/versification`)).status, 409);
});

test('pages and shared modules are served', async () => {
  for (const path of ['/', '/display', '/shared/detector.js', '/js/operator.js', '/js/display.js', '/css/operator.css', '/css/stage.css', '/img/logo.svg', '/js/transcription/pcm-worklet.js']) {
    assert.equal((await fetch(base + path)).status, 200, path);
  }
});

test('requests from other sites are refused', async () => {
  const foreign = await fetch(`${base}/api/config`, { headers: { Origin: 'https://evil.example' } });
  assert.equal(foreign.status, 403);
  const display = new WebSocket(`${wsBase}/ws/display`, { origin: 'https://evil.example' });
  const [error] = await once(display, 'error');
  assert.match(error.message, /403/);
  const transcribe = new WebSocket(`${wsBase}/ws/transcribe`, { origin: 'https://evil.example' });
  const [secondError] = await once(transcribe, 'error');
  assert.match(secondError.message, /403/);
});

test('display: state reaches screens, new screens catch up, and operators see the count', async () => {
  const operator = new WebSocket(`${wsBase}/ws/display?role=operator`);
  const fromOperator = messagesFrom(operator);
  await once(operator, 'open');
  await fromOperator((m) => m.type === 'screens' && m.count === 0);

  const screen = new WebSocket(`${wsBase}/ws/display`);
  const fromScreen = messagesFrom(screen);
  await once(screen, 'open');
  await fromScreen((m) => m.type === 'state');
  await fromOperator((m) => m.type === 'screens' && m.count === 1);

  const state = { blank: false, reference: 'John 3:16', pages: [[{ verse: 16, text: 'x' }]], page: 0 };
  const posted = await fetch(`${base}/api/display`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(state) });
  assert.deepEqual(await posted.json(), { screens: 1 });
  assert.deepEqual((await fromScreen((m) => m.type === 'state' && !m.state.blank)).state, state);

  const late = new WebSocket(`${wsBase}/ws/display`);
  const fromLate = messagesFrom(late);
  assert.equal((await fromLate((m) => m.type === 'state')).state.reference, 'John 3:16');

  screen.close();
  await once(screen, 'close');
  await fromOperator((m) => m.type === 'screens' && m.count === 1);
  late.close();
  await fromOperator((m) => m.type === 'screens' && m.count === 0);
  operator.close();
  await fetch(`${base}/api/display`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ blank: true }) });
});

test('transcription: audio is relayed, results come back, and the key stays on the server', async () => {
  received.frames.length = 0;
  received.text.length = 0;
  const client = new WebSocket(`${wsBase}/ws/transcribe`);
  const from = messagesFrom(client);
  await once(client, 'open');
  await from((m) => m.type === 'status' && m.state === 'connected');

  const url = new URL(received.url, 'http://x');
  assert.equal(url.searchParams.get('encoding'), 'linear16');
  assert.equal(url.searchParams.get('sample_rate'), '16000');
  assert.equal(url.searchParams.get('interim_results'), 'true');
  assert.equal(url.searchParams.get('mip_opt_out'), 'true');
  assert.equal(url.searchParams.get('endpointing'), '300', 'speech settings are unchanged');
  assert.equal(received.headers.authorization, 'Token good-key');

  client.send(Buffer.alloc(3200));
  const interim = await from((m) => m.type === 'transcript' && !m.isFinal);
  assert.equal(interim.text, 'john three');
  const final = await from((m) => m.type === 'transcript' && m.isFinal);
  assert.equal(final.text, 'john three sixteen');
  assert.equal(received.frames.length, 1);
  assert.equal(received.frames[0].length, 3200);

  // Pause: no audio flows, and keep-alives hold the stream open.
  await new Promise((resolve) => setTimeout(resolve, 150));
  assert.ok(received.text.some((m) => m.type === 'KeepAlive'), 'sends KeepAlive during silence');

  client.send(JSON.stringify({ type: 'finalize' }));
  client.send(JSON.stringify({ type: 'stop' }));
  await new Promise((resolve) => setTimeout(resolve, 50));
  assert.ok(received.text.some((m) => m.type === 'Finalize'));
  assert.ok(received.text.some((m) => m.type === 'CloseStream'));
  client.close();
});

test('transcription: the music profile changes Deepgram settings', async () => {
  const client = new WebSocket(`${wsBase}/ws/transcribe?profile=music`);
  const from = messagesFrom(client);
  await from((m) => m.type === 'status' && m.state === 'connected');
  assert.equal(new URL(received.url, 'http://x').searchParams.get('endpointing'), '500');
  client.close();
});

test('transcription: a refused key reports the reason and asks the browser not to retry', async () => {
  const refused = await startApp({ DEEPGRAM_API_KEY: 'bad-key', DEEPGRAM_URL: fake.url });
  const client = new WebSocket(`ws://127.0.0.1:${refused.port}/ws/transcribe`);
  const from = messagesFrom(client);
  const status = await from((m) => m.type === 'status');
  assert.equal(status.state, 'error');
  assert.equal(status.code, 'refused');
  assert.doesNotMatch(JSON.stringify(status), /bad-key/);
  const [code] = await once(client, 'close');
  assert.equal(code, 4401);
  await stopApp(refused);
});

test('transcription: an unreachable service reports an error and allows retrying', async () => {
  const offline = await startApp({ DEEPGRAM_API_KEY: 'good-key', DEEPGRAM_URL: 'ws://127.0.0.1:9/nope' });
  const client = new WebSocket(`ws://127.0.0.1:${offline.port}/ws/transcribe`);
  const from = messagesFrom(client);
  const status = await from((m) => m.type === 'status');
  assert.equal(status.code, 'upstream');
  const [code] = await once(client, 'close');
  assert.equal(code, 1011);
  await stopApp(offline);
});

test('transcription: no key configured', async () => {
  const unconfigured = await startApp({});
  const config = await (await fetch(`http://127.0.0.1:${unconfigured.port}/api/config`)).json();
  assert.equal(config.transcription.deepgram, false);
  const client = new WebSocket(`ws://127.0.0.1:${unconfigured.port}/ws/transcribe`);
  const from = messagesFrom(client);
  assert.equal((await from((m) => m.type === 'status')).code, 'not_configured');
  await stopApp(unconfigured);
});

test('transcripts are written only when posted, and the text is what was sent', async () => {
  assert.deepEqual(await readdir(transcriptDir), [], 'nothing saved by default');
  const posted = await fetch(`${base}/api/transcripts`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ text: 'Hello  church' }) });
  assert.equal(posted.status, 204);
  const [file] = await readdir(transcriptDir);
  assert.match(await readFile(join(transcriptDir, file), 'utf8'), /Hello church/);
  assert.equal((await fetch(`${base}/api/transcripts`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ text: '' }) })).status, 400);
});
