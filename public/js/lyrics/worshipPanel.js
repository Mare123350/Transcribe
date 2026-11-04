// The worship lyrics panel. Everything here also works by hand with no microphone, so the operator
// can always run a song manually, whatever happens to transcription or detection.
import { getLyricsSettings, updateLyricsSettings } from '/js/api.js';
import { LyricsEngine } from '/shared/lyrics/engine.js';
import { SAMPLE_SONGS } from '/shared/lyrics/sampleSongs.js';
import { classifyWorshipReference, routeFor } from '/shared/lyrics/serviceMode.js';
import { arrangementOf, lyricsScreen, sectionStops } from '/shared/lyrics/songs.js';
import { createLibraryDialog } from '/js/lyrics/libraryDialog.js';
import { createSetlistEditor } from '/js/lyrics/setlistEditor.js';
import { el } from '/js/lyrics/dom.js';

const $ = (id) => document.getElementById(id);
const SERVICE_KEY = 'transcribe-service-mode';

function loadServiceMode() {
  try {
    return localStorage.getItem(SERVICE_KEY) ?? 'sermon';
  } catch {
    return 'sermon';
  }
}

export function createWorshipPanel({ showOnScreen, clearScreen, showMessage, clearMessage, isDemo, getApprovalMode, usesBrowserSpeech, onAudioProfileChange, isListening }) {
  const state = {
    songs: [],
    setlists: [],
    settings: {},
    song: null,
    arrangement: [],
    index: 0,
    onScreen: false,
    interrupted: false, // a Bible passage is showing in the middle of a song
    serviceMode: loadServiceMode(),
    candidates: [],
    readySongId: null,
    autoFollow: true,
    hiddenBySilence: false, // automation took lyrics down, so it may put them back
    notice: '',
  };

  const engine = new LyricsEngine({ onEvent: handleEngineEvent });

  const library = createLibraryDialog({
    onSongsChanged: (songs) => {
      state.songs = songs;
      $('song-find-list').replaceChildren(...songs.map((song) => el('option', { value: song.title })));
      renderSetlist();
      refreshSongs();
    },
    onLoadSong: (song) => loadSong(song),
    getSettings: () => state.settings,
    onSettingsChanged: (settings) => {
      state.settings = settings;
      engine.setThresholds(settings.thresholds);
      refreshScreen();
    },
    showMessage,
  });

  const setlistEditor = createSetlistEditor({
    getSongs: () => state.songs,
    getActiveId: () => state.settings.activeSetlistId,
    onChanged: (setlists) => {
      state.setlists = setlists;
      renderSetlist();
      refreshSongs();
    },
    onUse: async (id) => {
      try {
        state.settings = await updateLyricsSettings({ activeSetlistId: id });
        renderSetlist();
        refreshSongs();
      } catch (error) {
        showMessage('library', `Couldn't set the active setlist: ${error.message}`, { kind: 'error' });
      }
    },
  });

  const activeSetlist = () => state.setlists.find((s) => s.id === state.settings.activeSetlistId) ?? null;
  const setlistSongs = () => (activeSetlist()?.songIds ?? []).map((id) => state.songs.find((s) => s.id === id)).filter(Boolean);
  const librarySongs = () => (isDemo() ? [...SAMPLE_SONGS, ...state.songs] : state.songs);

  // The sample songs only join the search in demo mode, and are never saved.
  function refreshSongs() {
    engine.setSongs({ setlist: setlistSongs(), library: librarySongs() });
    $('song-find-list').replaceChildren(...librarySongs().map((song) => el('option', { value: song.title })));
  }

  function renderSetlist() {
    const songs = setlistSongs();
    $('setlist-strip').hidden = !activeSetlist();
    $('setlist-strip-name').textContent = activeSetlist() ? `Service: ${activeSetlist().name}` : '';
    $('setlist-chips').replaceChildren(...songs.map((song, position) => el('button', {
      type: 'button',
      class: 'chip',
      'aria-pressed': String(state.song?.id === song.id),
      on: { click: () => chooseSong(song) },
    }, `${position + 1}. ${song.title}`)));
    const at = songs.findIndex((song) => song.id === state.song?.id);
    $('song-next-song').hidden = at < 0 || at >= songs.length - 1;
  }

  const songById = (id) => librarySongs().find((song) => song.id === id);

  function renderSuggestions() {
    const box = $('song-suggestions');
    const shown = state.candidates.filter((candidate) => songById(candidate.songId));
    box.hidden = !shown.length;
    box.replaceChildren(...shown.map((candidate) => {
      const song = songById(candidate.songId);
      const ready = candidate.songId === state.readySongId;
      const percent = Math.round(candidate.confidence * 100);
      return el('div', { class: 'suggestion', 'data-ready': String(ready) },
        el('div', { class: 'suggestion-title' }, song.title),
        el('div', { class: 'suggestion-meta' }, `${ready ? 'Ready to confirm' : 'Possible match'} · ${percent}% · ${candidate.scope === 'setlist' ? 'in setlist' : 'from library'}`),
        el('div', { class: 'suggestion-actions' },
          el('button', { type: 'button', class: ready ? 'button button-primary suggestion-confirm' : 'button suggestion-confirm', on: { click: () => confirmCandidate(candidate) } }, 'Confirm'),
          el('button', { type: 'button', class: 'link suggestion-reject', on: { click: () => rejectCandidate(candidate.songId) } }, 'Reject')));
    }));
  }

  function render() {
    renderSetlist();
    renderSuggestions();
    document.querySelectorAll('[data-service]').forEach((button) => {
      button.setAttribute('aria-checked', String(button.dataset.service === state.serviceMode));
    });
    const { song, arrangement, index } = state;
    $('song-now').hidden = !song;
    const flag = $('worship-state');
    flag.hidden = !song;
    flag.textContent = state.onScreen ? 'On screen' : 'Not on screen';
    flag.dataset.kind = state.onScreen ? 'live' : 'unsent';
    if (!song) return;

    const line = arrangement[index];
    const listening = isListening() && route().lyrics;
    const follow = $('follow-status');
    follow.textContent = !state.autoFollow ? 'Manual' : (listening ? 'Following' : 'Not listening');
    follow.dataset.kind = state.autoFollow && listening ? 'live' : 'unsent';
    $('follow-toggle').textContent = state.autoFollow ? 'Pause auto-follow' : 'Resume auto-follow';
    $('song-notice').textContent = state.notice;
    $('song-notice').hidden = !state.notice;
    $('song-title').textContent = song.title;
    $('song-current').textContent = line?.text ?? '';
    $('song-next').textContent = arrangement[index + 1]?.text ?? '(end of song)';
    $('line-prev').disabled = index <= 0;
    $('line-next').disabled = index >= arrangement.length - 1;
    $('lyrics-show').textContent = state.onScreen ? 'On Screen' : (state.interrupted ? 'Back to lyrics' : 'Show on screen');
    $('lyrics-show').disabled = state.onScreen;
    $('lyrics-blank').disabled = !state.onScreen;

    $('section-chips').replaceChildren(...sectionStops(arrangement).map((stop) => el('button', {
      type: 'button',
      class: 'chip',
      'aria-pressed': String(line?.orderIndex === arrangement[stop.index].orderIndex),
      on: { click: () => manualGoTo(stop.index) },
    }, stop.label)));
  }

  function refreshScreen() {
    if (state.onScreen && state.song) showOnScreen(lyricsScreen(state.song, state.arrangement, state.index, state.settings));
    render();
  }

  function goTo(index) {
    state.index = Math.max(0, Math.min(index, state.arrangement.length - 1));
    refreshScreen();
  }

  // Anything the operator does by hand stops automation until they turn it back on.
  function takeManualControl() {
    state.autoFollow = false;
    state.hiddenBySilence = false;
  }

  function manualGoTo(index) {
    takeManualControl();
    goTo(index);
    engine.setPosition(state.index);
  }

  function resumeFollow() {
    state.autoFollow = true;
    state.notice = '';
    const position = engine.position();
    if (position) state.index = position.index;
    state.onScreen = true;
    state.interrupted = false;
    refreshScreen();
  }

  function loadSong(song, index = 0) {
    state.autoFollow = true;
    state.hiddenBySilence = false;
    state.notice = '';
    state.song = song;
    state.arrangement = arrangementOf(song);
    state.index = index;
    state.interrupted = false;
    state.candidates = [];
    state.readySongId = null;
    refreshScreen();
  }

  // The operator picked this song themselves, so automation can't replace it.
  function chooseSong(song, index = 0) {
    engine.lock(song.id, { index, byOperator: true });
    loadSong(song, index);
  }

  function closeSong() {
    if (state.onScreen) clearScreen();
    engine.unlock();
    state.hiddenBySilence = false;
    state.notice = '';
    state.song = null;
    state.onScreen = false;
    state.interrupted = false;
    render();
  }

  function confirmCandidate(candidate) {
    const song = songById(candidate.songId);
    if (!song) return;
    const index = engine.startIndexFor(candidate);
    engine.lock(song.id, { index });
    loadSong(song, index);
    state.onScreen = true;
    refreshScreen();
  }

  function rejectCandidate(songId) {
    engine.reject(songId);
    state.candidates = state.candidates.filter((candidate) => candidate.songId !== songId);
    if (state.readySongId === songId) state.readySongId = null;
    render();
  }

  // The wrong song is on screen: take it down and stop suggesting it.
  function wrongSong() {
    const id = state.song?.id;
    closeSong();
    if (id) engine.reject(id);
  }

  function offerOrAccept(event) {
    if (getApprovalMode() === 'automatic') {
      confirmCandidate(event);
    } else {
      state.readySongId = event.songId;
      renderSuggestions();
    }
  }

  function handleEngineEvent(event) {
    switch (event.type) {
      case 'candidates':
        state.candidates = event.candidates;
        if (!event.candidates.some((c) => c.songId === state.readySongId)) state.readySongId = null;
        renderSuggestions();
        break;
      case 'proposal':
        offerOrAccept(event);
        break;
      case 'position':
        // While paused, the tracker keeps listening in the background but touches nothing on screen.
        if (state.autoFollow) goTo(event.index);
        break;
      case 'quiet':
        if (event.byOperator) {
          state.notice = 'No singing heard for a while. The lyrics stay up because you chose this song.';
        } else if (state.autoFollow) {
          state.notice = 'No singing heard, so the lyrics are off the screen. They return if the song resumes.';
          if (state.onScreen) {
            state.onScreen = false;
            state.hiddenBySilence = true;
            clearScreen();
          }
        } else {
          state.notice = 'No singing heard. Auto-follow is paused, so nothing has changed on screen.';
        }
        render();
        break;
      case 'resume':
        state.notice = '';
        if (state.hiddenBySilence && state.autoFollow) {
          state.hiddenBySilence = false;
          state.onScreen = true;
          state.index = event.index;
          refreshScreen();
        } else {
          render();
        }
        break;
      case 'ended':
        if (state.autoFollow && state.song?.id === event.songId) {
          if (state.onScreen) clearScreen();
          state.song = null;
          state.onScreen = false;
          state.interrupted = false;
          state.hiddenBySilence = false;
          state.notice = '';
          showMessage('song-ended', 'The song seems to have ended, so its lyrics were cleared.');
          render();
        } else if (state.song?.id === event.songId) {
          state.notice = 'The song seems to have ended. Auto-follow is paused, so its lyrics stay until you change them.';
          render();
        }
        break;
      case 'songChange':
        // Never replace a song the operator chose or is controlling. Just offer the new one.
        if (event.byOperator || !state.autoFollow) {
          state.readySongId = event.songId;
          renderSuggestions();
        } else {
          offerOrAccept(event);
        }
        break;
      default:
    }
  }

  function findAndLoad(event) {
    event.preventDefault();
    const query = $('song-find-input').value.trim().toLowerCase();
    if (!query) return;
    const songs = librarySongs();
    const song = songs.find((s) => s.title.toLowerCase() === query) ?? songs.find((s) => s.title.toLowerCase().includes(query));
    if (!song) {
      showMessage('library', `No song called “${$('song-find-input').value}” in the library.`);
      return;
    }
    $('song-find-input').value = '';
    chooseSong(song);
  }

  const audioProfile = () => (state.serviceMode === 'sermon' ? 'speech' : 'music');

  function warnAboutSource() {
    if (state.serviceMode !== 'sermon' && usesBrowserSpeech()) {
      showMessage('worship-source', "Browser speech recognition handles singing poorly and can't use the choir's audio input. Choose Deepgram for worship.");
    } else {
      clearMessage('worship-source');
    }
  }

  function setServiceMode(mode) {
    state.serviceMode = mode;
    try {
      localStorage.setItem(SERVICE_KEY, mode);
    } catch { /* the mode just won't persist */ }
    if (mode === 'sermon') {
      state.candidates = [];
      state.readySongId = null;
    }
    onAudioProfileChange(audioProfile());
    warnAboutSource();
    render();
  }

  const route = () => routeFor(state.serviceMode);

  function bind() {
    library.bind();
    setlistEditor.bind();
    document.querySelectorAll('[data-service]').forEach((button) => {
      button.addEventListener('click', () => setServiceMode(button.dataset.service));
    });
    $('source-select').addEventListener('change', warnAboutSource);
    $('song-next-song').addEventListener('click', () => {
      const songs = setlistSongs();
      const next = songs[songs.findIndex((song) => song.id === state.song?.id) + 1];
      if (next) chooseSong(next);
    });
    $('song-find').addEventListener('submit', findAndLoad);
    $('line-prev').addEventListener('click', () => manualGoTo(state.index - 1));
    $('line-next').addEventListener('click', () => manualGoTo(state.index + 1));
    $('lyrics-show').addEventListener('click', () => {
      state.onScreen = true;
      state.interrupted = false;
      state.hiddenBySilence = false;
      refreshScreen();
    });
    $('lyrics-blank').addEventListener('click', () => {
      takeManualControl();
      state.onScreen = false;
      clearScreen();
      render();
    });
    $('follow-toggle').addEventListener('click', () => {
      if (state.autoFollow) {
        takeManualControl();
        render();
      } else {
        resumeFollow();
      }
    });
    $('song-wrong').addEventListener('click', wrongSong);
    $('song-close').addEventListener('click', closeSong);
  }

  return {
    async init() {
      bind();
      try {
        state.settings = await getLyricsSettings();
        engine.setThresholds(state.settings.thresholds);
      } catch (error) {
        showMessage('library', `Couldn't load lyrics settings: ${error.message}`, { kind: 'error' });
      }
      await library.refresh();
      await setlistEditor.refresh().catch((error) => {
        showMessage('library', `Couldn't load setlists: ${error.message}`, { kind: 'error' });
      });
      refreshSongs();
      warnAboutSource();
      render();
      setInterval(() => {
        if (isListening() && route().lyrics) engine.tick();
      }, 1000);
    },
    refreshSongs,
    audioProfile,
    isWorshipActive: () => route().activity === 'worship',

    onFinal({ text, words }) {
      if (route().lyrics) engine.addFinal({ text, words });
    },
    onListeningChanged: render,

    // Decides what a Bible reference means right now. Returns it (perhaps changed), or null to drop it.
    checkVerseDetection(found) {
      if (route().activity !== 'worship') return found;
      const kind = classifyWorshipReference(found, { isLyric: (phrase) => engine.isLyricPhrase(phrase) });
      if (kind !== 'aside') return null;
      return {
        ...found,
        status: 'suggestion',
        aside: true,
        reasons: ['Heard during worship. It stays off screen unless you choose to show it, then press Back to lyrics.'],
      };
    },

    // A Bible passage went on screen.
    noteOtherContentShown() {
      if (state.onScreen && state.song) state.interrupted = true;
      state.onScreen = false;
      render();
    },
    noteBlanked() {
      takeManualControl();
      state.onScreen = false;
      render();
    },
  };
}
