// The operator dashboard: wires the transcript sources, the detector, Bible lookups, and the screen.
import { ApiError, getConfig, getPassage, getVersification, publishDisplay, saveTranscript } from '/js/api.js';
import { createWorshipPanel } from '/js/lyrics/worshipPanel.js';
import { createPaginator, createStage, fitStage, renderStage } from '/js/stage.js';
import { DeepgramSource } from '/js/transcription/deepgramSource.js';
import { DemoSource } from '/js/transcription/demoSource.js';
import { WebSpeechSource, isWebSpeechSupported } from '/js/transcription/webSpeechSource.js';
import { DEMO_TRANSCRIPTS } from '/shared/demoTranscripts.js';
import { ReferenceDetector } from '/shared/detector.js';
import { parseManualReference } from '/shared/parser.js';
import { adjacentRef, formatRef, parseRefKey, refKey } from '/shared/references.js';

const $ = (id) => document.getElementById(id);

const FONT_MIN = 40;
const FONT_MAX = 120;
const FONT_STEP = 6;
const MAX_TRANSCRIPT_LINES = 300;
const MAX_CARDS = 100;

// ---- Per-browser preferences. Everything else is gone when the page closes. ----

const PREFS_KEY = 'scripture-screen-prefs'; // the app's earlier name, kept so saved settings carry over
function loadPrefs() {
  try {
    return JSON.parse(localStorage.getItem(PREFS_KEY)) ?? {};
  } catch {
    return {};
  }
}
const prefs = { mode: 'review', fontPx: 68, theme: 'black', ...loadPrefs() };
function savePrefs() {
  try {
    localStorage.setItem(PREFS_KEY, JSON.stringify(prefs));
  } catch { /* preferences just won't persist */ }
}

// ---- State ----

const state = {
  config: null,
  versification: null,
  demo: false,
  source: null,
  listen: 'idle', // idle | requesting | listening | paused | reconnecting | error
  cards: [],
  nextCardId: 1,
  history: [],
  preview: null, // { ref, passage, pages, page }
  live: null,
  saveTranscripts: false,
  previewRequest: 0,
};

const previewStage = createStage($('preview-frame'));
const liveStage = createStage($('live-frame'));
const paginator = createPaginator();
fitStage($('preview-frame'), previewStage);
fitStage($('live-frame'), liveStage);

// ---- Status messages ----

const messages = new Map();
function showMessage(id, text, { kind = 'warn', action } = {}) {
  messages.set(id, { text, kind, action });
  renderMessages();
}
function clearMessage(id) {
  if (messages.delete(id)) renderMessages();
}
function renderMessages() {
  $('messages').replaceChildren(...[...messages.entries()].map(([id, { text, kind, action }]) => {
    const row = document.createElement('div');
    row.className = 'message';
    row.dataset.kind = kind;
    const span = document.createElement('span');
    span.textContent = text;
    row.append(span);
    if (action) {
      const button = document.createElement('button');
      button.type = 'button';
      button.className = 'button';
      button.textContent = action.label;
      button.addEventListener('click', () => { clearMessage(id); action.run(); });
      row.append(button);
    } else {
      const button = document.createElement('button');
      button.type = 'button';
      button.className = 'link';
      button.textContent = 'Dismiss';
      button.addEventListener('click', () => clearMessage(id));
      row.append(button);
    }
    return row;
  }));
}

// ---- Translations ----

const translationById = (id) => state.config.translations.find((t) => t.id === id);

function renderTranslationSelect() {
  const select = $('default-translation');
  select.replaceChildren(...state.config.translations.map((t) => {
    const option = new Option(t.available ? `${t.abbreviation} · ${t.name}` : `${t.abbreviation} · not configured`, t.id);
    option.disabled = !t.available;
    option.title = t.unavailableReason ?? '';
    return option;
  }));
  select.value = prefs.translation;
}

function renderVersionChips() {
  const current = state.preview?.passage.translation.id;
  $('version-chips').replaceChildren(...state.config.translations.map((t) => {
    const chip = document.createElement('button');
    chip.type = 'button';
    chip.className = 'chip';
    chip.textContent = t.abbreviation;
    chip.disabled = !t.available || !state.preview;
    chip.title = t.available ? t.name : `${t.name}: ${t.unavailableReason}`;
    chip.setAttribute('aria-pressed', String(t.id === current));
    chip.addEventListener('click', () => {
      if (t.id !== current) loadPreview(state.preview.ref, t.id, { keepLive: true });
    });
    return chip;
  }));
}

async function useDefaultTranslation(id) {
  try {
    state.versification = await getVersification(id);
    prefs.translation = id;
    savePrefs();
    detector.setVersification(state.versification);
    clearMessage('translation');
  } catch (error) {
    showMessage('translation', `Couldn't load ${id.toUpperCase()}: ${error.message}`, { kind: 'error' });
    $('default-translation').value = prefs.translation;
  }
}

// ---- Detector ----

const detector = new ReferenceDetector({
  versification: { exact: false, books: {} },
  onDetection: (found) => {
    const checked = worship ? worship.checkVerseDetection(found) : found;
    if (checked) addDetection(checked);
  },
  onRepeat: (found) => {
    const card = state.cards.find((c) => c.key === found.key);
    if (card) {
      card.repeats++;
      renderCards();
    }
    highlightPhrase(found.phrase);
  },
  onTentative: (detected) => {
    const found = worship?.isWorshipActive() ? [] : detected; // sung words shouldn't flicker up here
    const hearing = $('hearing');
    hearing.hidden = !found.length;
    hearing.replaceChildren();
    if (found.length) {
      const strong = document.createElement('strong');
      strong.textContent = found.map((d) => formatRef(d.refs[0])).join(', ');
      hearing.append('Hearing: ', strong, '…');
    }
  },
});

// ---- Transcript ----

let transcriptLines = [];
let interimText = '';

function renderTranscript() {
  const box = $('transcript');
  const atBottom = box.scrollHeight - box.scrollTop - box.clientHeight < 40;
  const nodes = transcriptLines.map((line) => {
    const p = document.createElement('p');
    let cursor = 0;
    for (const phrase of line.marks) {
      const at = line.text.indexOf(phrase, cursor);
      if (at < 0) continue;
      p.append(line.text.slice(cursor, at));
      const mark = document.createElement('mark');
      mark.textContent = phrase;
      p.append(mark);
      cursor = at + phrase.length;
    }
    p.append(line.text.slice(cursor));
    return p;
  });
  if (interimText) {
    const p = document.createElement('p');
    p.className = 'interim';
    p.textContent = interimText;
    nodes.push(p);
  }
  if (nodes.length) box.replaceChildren(...nodes);
  if (atBottom) box.scrollTop = box.scrollHeight;
}

// Marks a detected phrase in the most recent line that contains it.
function highlightPhrase(phrase) {
  if (!phrase) return;
  for (let i = transcriptLines.length - 1; i >= 0; i--) {
    const line = transcriptLines[i];
    if (line.text.includes(phrase)) {
      line.marks = [...line.marks, phrase].sort((a, b) => line.text.indexOf(a) - line.text.indexOf(b));
      break;
    }
  }
  renderTranscript();
}

function handleTranscript({ text, isFinal, words }) {
  if (isFinal) {
    interimText = '';
    if (text.trim()) {
      transcriptLines.push({ text: text.trim(), marks: [] });
      if (transcriptLines.length > MAX_TRANSCRIPT_LINES) transcriptLines.shift();
      if (state.saveTranscripts && !state.demo) {
        saveTranscript(text).then(() => clearMessage('saving')).catch((error) => {
          showMessage('saving', `Transcript isn't being saved: ${error.message}`, { kind: 'error' });
        });
      }
    }
    renderTranscript();
    worship?.onFinal({ text, words }); // first, so the verse check knows whether these were lyrics
    detector.addFinal(text);
  } else {
    interimText = text;
    renderTranscript();
    detector.addInterim(text);
  }
}

// ---- Listening ----

const LISTEN_TEXT = {
  idle: 'Not listening',
  requesting: 'Starting…',
  listening: 'LISTENING',
  paused: 'Paused: not sending audio',
  reconnecting: 'Reconnecting…',
  error: 'Stopped: see message',
};

function setListen(status) {
  state.listen = status;
  renderListen();
  worship?.onListeningChanged();
}

function renderListen() {
  const { listen, demo } = state;
  const running = !['idle', 'error'].includes(listen);
  const indicator = $('listen-status');
  indicator.dataset.state = listen;
  indicator.dataset.demo = String(demo);
  $('listen-text').textContent = demo && listen === 'listening' ? 'DEMO PLAYING' : LISTEN_TEXT[listen];
  $('start').disabled = running;
  $('start').textContent = demo ? 'Play sample' : 'Start';
  $('pause').disabled = !running || listen === 'requesting';
  $('pause').textContent = listen === 'paused' ? 'Resume' : 'Pause';
  $('stop').disabled = !running;
  $('source-select').disabled = running;
  $('device-select').disabled = running || $('source-select').value !== 'deepgram';
  $('demo-select').disabled = running;
  $('demo-speed').disabled = running;
  $('demo-toggle').disabled = running;
  document.title = listen === 'listening' && !demo ? '● Listening · Transcribe' : 'Transcribe';
}

function onSourceStatus({ state: status, message }) {
  setListen(status);
  if (status === 'error') {
    state.source = null;
    detector.flush();
    showMessage('transcription', message, { kind: 'error' });
    $('meter-bar').style.transform = 'scaleX(0)';
  } else if (status === 'reconnecting') {
    showMessage('transcription', message ?? 'Reconnecting to transcription…');
  } else if (status === 'listening') {
    clearMessage('transcription');
  }
}

function micErrorMessage(error) {
  switch (error.name) {
    case 'NotAllowedError': return 'Microphone access was blocked. Allow it from the icon in the address bar, then press Start again.';
    case 'NotFoundError':
    case 'OverconstrainedError': return "That audio input isn't available. Check the cable, or choose another input.";
    case 'NotReadableError': return 'Another app is using the audio input, or the system blocked it.';
    default: return `Couldn't start the microphone: ${error.message}`;
  }
}

async function start() {
  clearMessage('transcription');
  const common = { onTranscript: handleTranscript, onStatus: onSourceStatus };
  try {
    if (state.demo) {
      state.source = new DemoSource({
        ...common,
        transcript: DEMO_TRANSCRIPTS.find((d) => d.id === $('demo-select').value),
        speed: Number($('demo-speed').value),
        onFinished: stop,
      });
    } else if ($('source-select').value === 'deepgram') {
      state.source = new DeepgramSource({ ...common, onLevel: (level) => { $('meter-bar').style.transform = `scaleX(${Math.min(1, level * 1.5)})`; } });
    } else if ($('source-select').value === 'webspeech') {
      state.source = new WebSpeechSource({ ...common, language: state.config.transcription.language });
    } else {
      showMessage('transcription', 'No transcription is available in this browser. Set up Deepgram, use Chrome or Edge, or try Demo mode.', { kind: 'error' });
      return;
    }
    const source = state.source;
    const stalled = setTimeout(() => {
      if (state.source === source && state.listen === 'requesting') {
        showMessage('transcription', "Still waiting for the microphone. Look for a permission prompt near the browser's address bar, or press Stop and try again.");
      }
    }, 8000);
    try {
      await source.start({ deviceId: $('device-select').value, profile: worship?.audioProfile() ?? 'speech' });
    } catch (error) {
      if (state.source !== source) return; // the operator already pressed Stop
      throw error;
    } finally {
      clearTimeout(stalled);
    }
    if (!state.demo) refreshDevices();
  } catch (error) {
    state.source?.stop();
    state.source = null;
    setListen('error');
    showMessage('transcription', micErrorMessage(error), { kind: 'error' });
  }
}

function togglePause() {
  if (!state.source) return;
  if (state.listen === 'paused') {
    state.source.resume();
  } else {
    state.source.pause();
    interimText = '';
    renderTranscript();
    detector.flush();
    $('meter-bar').style.transform = 'scaleX(0)';
  }
}

function stop() {
  state.source?.stop();
  state.source = null;
  interimText = '';
  renderTranscript();
  detector.flush();
  setListen('idle');
  clearMessage('transcription');
  $('meter-bar').style.transform = 'scaleX(0)';
}

async function refreshDevices() {
  const select = $('device-select');
  try {
    const devices = (await navigator.mediaDevices.enumerateDevices()).filter((d) => d.kind === 'audioinput');
    const hasLabels = devices.some((d) => d.label);
    select.replaceChildren(...devices.map((device, index) => new Option(device.label || `Audio input ${index + 1}`, device.deviceId)));
    if (!devices.length) select.append(new Option('No audio inputs found', ''));
    if (devices.some((d) => d.deviceId === prefs.deviceId)) select.value = prefs.deviceId;
    $('allow-mic').hidden = hasLabels || !devices.length || $('source-select').value !== 'deepgram';
    clearMessage('devices');
  } catch {
    showMessage('devices', "This browser can't list audio inputs.");
  }
}

async function allowMicrophone() {
  try {
    const stream = await navigator.mediaDevices.getUserMedia({ audio: true });
    for (const track of stream.getTracks()) track.stop();
    await refreshDevices();
  } catch (error) {
    showMessage('transcription', micErrorMessage(error), { kind: 'error' });
  }
}

function renderSourceNote() {
  const source = $('source-select').value;
  $('source-note').textContent = {
    deepgram: 'Your browser will ask for microphone access. Audio goes to Deepgram through this server and is not saved here.',
    webspeech: 'Uses the computer’s default microphone, chosen in system settings. Your browser will ask for access, and Chrome sends audio to Google. Set up Deepgram to pick a specific input.',
    none: 'This browser has no speech recognition. Add a Deepgram key, use Chrome or Edge, or try Demo mode.',
  }[source] ?? '';
  $('allow-mic').hidden = source !== 'deepgram';
  renderListen();
}

function setDemo(on) {
  state.demo = on;
  $('demo-toggle').setAttribute('aria-pressed', String(on));
  $('demo-banner').hidden = !on;
  $('live-controls').hidden = on;
  $('demo-controls').hidden = !on;
  $('demo-description').textContent = DEMO_TRANSCRIPTS.find((d) => d.id === $('demo-select').value)?.description ?? '';
  worship?.refreshSongs();
  renderListen();
}

// ---- Detected reference cards ----

function addDetection(found) {
  highlightPhrase(found.phrase);
  const card = {
    id: state.nextCardId++,
    status: found.status,
    options: found.refs,
    alternates: found.alternates,
    selected: 0,
    key: found.key,
    phrase: found.phrase,
    reasons: found.reasons,
    passage: null,
    lookup: found.status === 'invalid' ? 'none' : 'loading',
    sent: false,
    repeats: 0,
    aside: Boolean(found.aside),
  };
  state.cards.unshift(card);
  state.cards.length = Math.min(state.cards.length, MAX_CARDS);
  renderCards();
  if (card.lookup === 'loading') lookupCard(card);
}

const cardRef = (card) => [...card.options, ...card.alternates][card.selected];

async function lookupCard(card) {
  const ref = cardRef(card);
  const translation = prefs.translation;
  card.lookup = 'loading';
  card.lookupError = null;
  renderCards();
  try {
    const passage = await getPassage(refKey(ref), translation);
    if (cardRef(card) !== ref) return; // the operator picked something else in the meantime
    card.passage = passage;
    card.lookup = 'ready';
    clearMessage('lookup');
    if (card.status === 'invalid') card.status = 'suggestion'; // corrected into something real
    afterCardReady(card);
  } catch (error) {
    if (cardRef(card) !== ref) return;
    card.passage = null;
    if (error.code === 'not_found') {
      card.status = 'invalid';
      card.reasons = [error.message];
      card.lookup = 'none';
    } else {
      card.lookup = 'error';
      card.lookupError = error.message;
      showMessage('lookup', `Bible lookup failed: ${error.message} The screen hasn't changed.`, { kind: 'error' });
    }
  }
  renderCards();
}

function afterCardReady(card) {
  if (card.manual) {
    setPreview(cardRef(card), card.passage); // the operator just corrected this, so show the result
    return;
  }
  if (card.autoHandled) return;
  card.autoHandled = true;
  if (prefs.mode === 'automatic' && card.status === 'confirmed' && !card.aside) {
    setPreview(card.options[0], card.passage);
    sendToScreen({ automatic: true });
    card.sent = true;
  } else if (!state.preview || isPreviewLive()) {
    // Queue up the newest reference so one press of Send puts it on screen, but never replace
    // a preview the operator hasn't sent yet.
    setPreview(cardRef(card), card.passage);
  }
}

function badgeText(card) {
  if (card.sent) return 'Sent to screen';
  if (card.status === 'invalid') return 'Not found';
  if (card.aside) return 'Mentioned during worship';
  if (card.status === 'suggestion') return 'Needs confirmation';
  return 'Confirmed';
}

function renderCards() {
  const container = $('cards');
  const open = state.cards.filter((c) => !c.sent && c.status !== 'invalid').length;
  $('queue-count').textContent = open ? `${open} waiting` : '';
  if (!state.cards.length) {
    const empty = document.createElement('p');
    empty.className = 'empty';
    empty.textContent = 'References the preacher mentions will appear here.';
    container.replaceChildren(empty);
    return;
  }

  // Keep a correction form that's being typed in alive across re-renders.
  const editing = new Map();
  for (const form of container.querySelectorAll('.card-correct:not([hidden])')) {
    const input = form.querySelector('input');
    editing.set(Number(form.closest('.card').dataset.id), { value: input.value, focused: document.activeElement === input });
  }

  container.replaceChildren(...state.cards.map((card) => {
    const node = $('card-template').content.firstElementChild.cloneNode(true);
    node.dataset.id = card.id;
    node.dataset.status = card.status;
    node.dataset.sent = String(card.sent);
    node.querySelector('.card-ref').textContent = formatRef(cardRef(card));
    node.querySelector('.badge').textContent = badgeText(card);
    const repeatNote = card.repeats ? ` · said again ×${card.repeats}` : '';
    node.querySelector('.card-heard').textContent = card.manualText ? `Corrected by operator${repeatNote}` : `Heard: “${card.phrase}”${repeatNote}`;
    node.querySelector('.card-reason').textContent = card.reasons.join(' ');

    const choices = [...card.options, ...card.alternates];
    const optionBox = node.querySelector('.card-options');
    if (choices.length > 1) {
      choices.forEach((ref, index) => {
        const chip = document.createElement('button');
        chip.type = 'button';
        chip.className = 'chip';
        chip.textContent = formatRef(ref);
        chip.setAttribute('aria-pressed', String(index === card.selected));
        chip.addEventListener('click', () => {
          card.selected = index;
          lookupCard(card);
        });
        optionBox.append(chip);
      });
    }

    const text = node.querySelector('.card-text');
    if (card.lookup === 'loading') text.textContent = 'Looking up…';
    else if (card.lookup === 'error') text.textContent = card.lookupError;
    else if (card.passage) text.textContent = card.passage.verses.map((v) => v.text).join(' ');

    const canUse = card.lookup === 'ready';
    const sendButton = node.querySelector('.card-send');
    sendButton.hidden = card.status === 'invalid';
    sendButton.disabled = !canUse;
    sendButton.textContent = card.sent ? 'Send again' : (card.aside ? 'Show briefly' : 'Send to Screen');
    sendButton.addEventListener('click', () => {
      setPreview(cardRef(card), card.passage);
      sendToScreen();
      card.sent = true;
      renderCards();
    });
    const previewButton = node.querySelector('.card-preview');
    previewButton.hidden = card.status === 'invalid';
    previewButton.disabled = !canUse;
    previewButton.addEventListener('click', () => setPreview(cardRef(card), card.passage));

    const form = node.querySelector('.card-correct');
    const input = form.querySelector('input');
    const formError = node.querySelector('.card-correct-error');
    node.querySelector('.card-fix').addEventListener('click', () => {
      form.hidden = !form.hidden;
      if (!form.hidden) {
        input.value = formatRef(cardRef(card));
        input.focus();
        input.select();
      }
    });
    form.addEventListener('submit', (event) => {
      event.preventDefault();
      const parsed = parseManualReference(input.value, state.versification);
      if (parsed.error) {
        formError.textContent = parsed.error;
        formError.hidden = false;
        return;
      }
      card.options = parsed.refs;
      card.alternates = parsed.alternates ?? [];
      card.selected = 0;
      card.status = 'suggestion';
      card.reasons = [];
      card.manualText = input.value;
      card.manual = true;
      card.key = parsed.refs.map(refKey).join('|');
      lookupCard(card);
    });
    const held = editing.get(card.id);
    if (held) {
      form.hidden = false;
      input.value = held.value;
      if (held.focused) queueMicrotask(() => input.focus());
    }

    const retry = node.querySelector('.card-retry');
    retry.hidden = card.lookup !== 'error';
    retry.addEventListener('click', () => lookupCard(card));
    node.querySelector('.card-dismiss').addEventListener('click', () => {
      state.cards = state.cards.filter((c) => c !== card);
      renderCards();
    });
    return node;
  }));
}

// ---- Preview and congregation screen ----

const stageState = (entry) => (entry?.external ? {
  ...entry.external,
  fontPx: prefs.fontPx,
  theme: prefs.theme,
  demo: state.demo,
} : entry ? {
  blank: false,
  reference: entry.passage.reference,
  translation: entry.passage.translation,
  copyright: entry.passage.copyright,
  pages: entry.pages,
  page: entry.page,
  fontPx: prefs.fontPx,
  theme: prefs.theme,
  demo: entry.demo,
} : { blank: true, theme: prefs.theme });

const sameEntry = (a, b) => Boolean(a?.passage && b?.passage)
  && a.passage.reference === b.passage.reference
  && a.passage.translation.id === b.passage.translation.id;

const isPreviewLive = () => sameEntry(state.preview, state.live);

function buildEntry(ref, passage) {
  return {
    ref,
    passage,
    pages: paginator({ passage, reference: passage.reference, fontPx: prefs.fontPx }),
    page: 0,
    demo: state.demo,
  };
}

function setPreview(ref, passage) {
  state.previewRequest++; // anything still loading is now out of date
  state.preview = buildEntry(ref, passage);
  $('preview-error').hidden = true;
  renderPreview();
}

function renderPreview() {
  const { preview, live } = state;
  renderStage(previewStage, preview ? stageState(preview) : { blank: true, theme: prefs.theme });
  $('preview-empty').hidden = Boolean(preview);
  renderVersionChips();

  const onScreen = isPreviewLive();
  const flag = $('preview-flag');
  flag.hidden = !preview;
  flag.textContent = onScreen ? 'On screen' : 'Not on screen yet';
  flag.dataset.kind = onScreen ? 'live' : 'unsent';

  $('send').disabled = !preview || (onScreen && preview.page === live.page);
  $('send').textContent = onScreen ? 'On Screen' : 'Send to Screen';

  const pageCount = preview?.pages.length ?? 0;
  $('page-indicator').textContent = pageCount ? `${preview.page + 1} / ${pageCount}` : '–';
  $('prev-page').disabled = !preview || preview.page <= 0;
  $('next-page').disabled = !preview || preview.page >= pageCount - 1;
  $('prev-verse').disabled = !preview || !adjacentRef(preview.ref, -1, state.versification);
  $('next-verse').disabled = !preview || !adjacentRef(preview.ref, 1, state.versification);
}

async function publish() {
  try {
    const { screens } = await publishDisplay(stageState(state.live));
    clearMessage('display');
    if (!screens) {
      showMessage('display', 'No display window is open, so the congregation sees nothing yet.', {
        action: { label: 'Open display window', run: openDisplay },
      });
    }
  } catch (error) {
    showMessage('display', `Couldn't update the screen: ${error.message}`, { kind: 'error' });
  }
}

function renderLive() {
  renderStage(liveStage, stageState(state.live));
}

// The worship panel puts lyrics on the screen through here.
function showExternal(content) {
  state.live = { external: content };
  renderLive();
  renderPreview();
  publish();
}

function sendToScreen({ automatic = false } = {}) {
  if (!state.preview) return;
  worship?.noteOtherContentShown({ automatic });
  state.live = { ...state.preview };
  const entry = state.live;
  const latest = state.history[0];
  if (!latest || latest.key !== refKey(entry.ref) || latest.passage.translation.id !== entry.passage.translation.id) {
    state.history.unshift({ key: refKey(entry.ref), ref: entry.ref, passage: entry.passage, at: new Date() });
    renderHistory();
  }
  renderLive();
  renderPreview();
  publish();
}

function clearScreen() {
  worship?.noteBlanked();
  state.live = null;
  renderLive();
  renderPreview();
  publish();
}

// Loads a passage into the preview. `keepLive` means this is the operator adjusting the current
// passage, which in automatic mode should follow through to the screen.
async function loadPreview(ref, translationId, { keepLive = false } = {}) {
  const request = ++state.previewRequest;
  const wasLive = isPreviewLive();
  const errorBox = $('preview-error');
  try {
    const passage = await getPassage(refKey(ref), translationId);
    if (request !== state.previewRequest) return;
    setPreview(ref, passage);
    clearMessage('lookup');
    if (keepLive && wasLive && prefs.mode === 'automatic') sendToScreen();
  } catch (error) {
    if (request !== state.previewRequest) return;
    const abbreviation = translationById(translationId)?.abbreviation ?? translationId;
    errorBox.textContent = error instanceof ApiError && error.code === 'not_found'
      ? error.message
      : `Couldn't load ${formatRef(ref)} in ${abbreviation}: ${error.message} Nothing has changed on screen.`;
    errorBox.hidden = false;
    renderVersionChips();
  }
}

function moveVerse(direction) {
  if (!state.preview) return;
  const next = adjacentRef(state.preview.ref, direction, state.versification);
  if (next) loadPreview(next, state.preview.passage.translation.id, { keepLive: true });
}

function movePage(direction) {
  const { preview } = state;
  if (!preview) return;
  const page = preview.page + direction;
  if (page < 0 || page >= preview.pages.length) return;
  const onScreen = isPreviewLive();
  preview.page = page;
  if (onScreen) {
    // Turning the page of the passage on screen is immediate in both modes.
    state.live.page = page;
    renderLive();
    publish();
  }
  renderPreview();
}

function repaginate(entry) {
  if (!entry?.passage) return;
  const firstVerse = entry.pages[entry.page]?.[0]?.verse;
  entry.pages = paginator({ passage: entry.passage, reference: entry.passage.reference, fontPx: prefs.fontPx });
  const page = entry.pages.findLastIndex((p) => p[0].verse <= firstVerse);
  entry.page = Math.max(page, 0);
}

function changeFont(step) {
  const size = Math.max(FONT_MIN, Math.min(FONT_MAX, prefs.fontPx + step));
  if (size === prefs.fontPx) return;
  prefs.fontPx = size;
  savePrefs();
  applyDisplayPrefs();
}

function applyDisplayPrefs() {
  $('font-size').textContent = `${prefs.fontPx}`;
  $('font-down').disabled = prefs.fontPx <= FONT_MIN;
  $('font-up').disabled = prefs.fontPx >= FONT_MAX;
  repaginate(state.preview);
  repaginate(state.live);
  renderPreview();
  renderLive();
  publish();
}

function renderHistory() {
  const list = $('history');
  if (!state.history.length) return;
  list.replaceChildren(...state.history.map((item) => {
    const row = document.createElement('li');
    const button = document.createElement('button');
    button.type = 'button';
    const name = document.createElement('span');
    name.textContent = `${item.passage.reference} (${item.passage.translation.abbreviation})`;
    const time = document.createElement('time');
    time.textContent = item.at.toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' });
    button.append(name, time);
    button.addEventListener('click', () => setPreview(item.ref, item.passage));
    row.append(button);
    return row;
  }));
}

function openDisplay() {
  window.open('/display', 'transcribe-display', 'popup,width=960,height=540');
}

// ---- Screen count ----

function watchScreens() {
  const socket = new WebSocket(`${location.protocol === 'https:' ? 'wss:' : 'ws:'}//${location.host}/ws/display?role=operator`);
  const pill = $('screens-pill');
  socket.addEventListener('open', () => clearMessage('server'));
  socket.addEventListener('message', (event) => {
    const message = JSON.parse(event.data);
    if (message.type !== 'screens') return;
    pill.textContent = message.count === 1 ? '1 screen' : message.count ? `${message.count} screens` : 'No screens';
    pill.dataset.ok = String(message.count > 0);
    if (message.count > 0) clearMessage('display');
  });
  socket.addEventListener('close', () => {
    pill.textContent = 'Server disconnected';
    pill.dataset.ok = 'false';
    showMessage('server', 'Lost contact with the Transcribe server. Trying to reconnect…', { kind: 'error' });
    setTimeout(watchScreens, 2000);
  });
}

// ---- Worship lyrics ----

let worship = null;

// ---- Wiring ----

function bindEvents() {
  document.querySelectorAll('[data-mode]').forEach((button) => {
    button.addEventListener('click', () => {
      prefs.mode = button.dataset.mode;
      savePrefs();
      renderMode();
    });
  });
  $('default-translation').addEventListener('change', (event) => useDefaultTranslation(event.target.value));
  $('open-display').addEventListener('click', openDisplay);
  $('demo-toggle').addEventListener('click', () => setDemo(!state.demo));
  $('open-settings').addEventListener('click', () => $('settings').showModal());
  $('save-transcripts').addEventListener('change', (event) => { state.saveTranscripts = event.target.checked; });

  $('start').addEventListener('click', start);
  $('pause').addEventListener('click', togglePause);
  $('stop').addEventListener('click', stop);
  $('allow-mic').addEventListener('click', allowMicrophone);
  $('source-select').addEventListener('change', (event) => {
    prefs.source = event.target.value;
    savePrefs();
    renderSourceNote();
  });
  $('device-select').addEventListener('change', (event) => {
    prefs.deviceId = event.target.value;
    savePrefs();
  });
  navigator.mediaDevices?.addEventListener('devicechange', refreshDevices);

  $('demo-select').addEventListener('change', () => setDemo(true));
  $('demo-say').addEventListener('submit', (event) => {
    event.preventDefault();
    const input = $('demo-say-input');
    if (input.value.trim()) handleTranscript({ text: input.value, isFinal: true });
    input.value = '';
  });

  $('clear-transcript').addEventListener('click', () => {
    transcriptLines = [];
    interimText = '';
    const empty = document.createElement('p');
    empty.className = 'empty';
    empty.textContent = 'The transcript is empty.';
    $('transcript').replaceChildren(empty);
  });

  $('search').addEventListener('submit', (event) => {
    event.preventDefault();
    const text = $('search-input').value.trim();
    const errorBox = $('search-error');
    errorBox.hidden = true;
    if (!text) return;
    const parsed = parseManualReference(text, state.versification);
    if (parsed.error) {
      errorBox.textContent = parsed.error;
      errorBox.hidden = false;
      return;
    }
    if (parsed.refs.length > 1) {
      // A choice is needed ("Corinthians 13"), so offer it as a card rather than guessing.
      addDetection({ status: 'suggestion', refs: parsed.refs, alternates: [], key: parsed.refs.map(refKey).join('|'), phrase: text, reasons: ['Please choose which book you meant.'] });
    } else {
      loadPreview(parsed.refs[0], prefs.translation);
    }
    $('search-input').select();
  });

  $('send').addEventListener('click', () => sendToScreen());
  $('clear-screen').addEventListener('click', clearScreen);
  $('prev-verse').addEventListener('click', () => moveVerse(-1));
  $('next-verse').addEventListener('click', () => moveVerse(1));
  $('prev-page').addEventListener('click', () => movePage(-1));
  $('next-page').addEventListener('click', () => movePage(1));
  $('font-down').addEventListener('click', () => changeFont(-FONT_STEP));
  $('font-up').addEventListener('click', () => changeFont(FONT_STEP));
  $('theme-select').addEventListener('change', (event) => {
    prefs.theme = event.target.value;
    savePrefs();
    applyDisplayPrefs();
  });

  document.addEventListener('keydown', (event) => {
    if (event.target.closest('input, select, textarea, dialog') || event.metaKey || event.ctrlKey || event.altKey) return;
    if (event.key === 'ArrowRight') movePage(1);
    if (event.key === 'ArrowLeft') movePage(-1);
  });

  window.addEventListener('beforeunload', () => state.source?.stop());
}

function renderMode() {
  document.querySelectorAll('[data-mode]').forEach((button) => {
    button.setAttribute('aria-checked', String(button.dataset.mode === prefs.mode));
  });
}

async function init() {
  bindEvents();
  renderMode();

  $('demo-select').replaceChildren(...DEMO_TRANSCRIPTS.map((d) => new Option(d.title, d.id)));
  $('theme-select').value = prefs.theme;
  $('font-size').textContent = `${prefs.fontPx}`;
  renderStage(previewStage, { blank: true, theme: prefs.theme });
  renderStage(liveStage, { blank: true, theme: prefs.theme });
  $('send').disabled = true;

  try {
    state.config = await getConfig();
  } catch (error) {
    showMessage('server', error.message, { kind: 'error', action: { label: 'Try again', run: () => location.reload() } });
    return;
  }

  $('transcript-dir').textContent = state.config.transcriptDirectory;

  const available = state.config.translations.filter((t) => t.available);
  if (!available.some((t) => t.id === prefs.translation)) {
    prefs.translation = available.some((t) => t.id === state.config.defaultTranslation) ? state.config.defaultTranslation : available[0].id;
  }
  renderTranslationSelect();
  await useDefaultTranslation(prefs.translation);

  // Transcription options, best first.
  const sources = [];
  if (state.config.transcription.deepgram) sources.push(new Option('Deepgram (choose any input)', 'deepgram'));
  if (isWebSpeechSupported()) sources.push(new Option('Browser speech recognition (default mic)', 'webspeech'));
  if (!sources.length) sources.push(new Option('None available', 'none'));
  $('source-select').replaceChildren(...sources);
  if (sources.some((option) => option.value === prefs.source)) $('source-select').value = prefs.source;

  renderSourceNote();
  refreshDevices();
  renderPreview();
  renderLive();
  setDemo(new URLSearchParams(location.search).has('demo'));
  watchScreens();
  worship = createWorshipPanel({
    showOnScreen: showExternal,
    clearScreen: () => {
      state.live = null;
      renderLive();
      renderPreview();
      publish();
    },
    isDemo: () => state.demo,
    getApprovalMode: () => prefs.mode,
    usesBrowserSpeech: () => !state.demo && $('source-select').value === 'webspeech',
    onAudioProfileChange: (profile) => state.source?.setProfile?.(profile),
    isListening: () => state.listen === 'listening',
    showMessage,
    clearMessage,
  });
  worship.init();
}

init();
