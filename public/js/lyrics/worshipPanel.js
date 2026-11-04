// The worship lyrics panel. Everything here works by hand with no microphone, so the operator can
// always run a song manually, whatever happens to transcription or detection.
import { getLyricsSettings } from '/js/api.js';
import { arrangementOf, lyricsScreen, sectionStops } from '/shared/lyrics/songs.js';
import { createLibraryDialog } from '/js/lyrics/libraryDialog.js';
import { el } from '/js/lyrics/dom.js';

const $ = (id) => document.getElementById(id);

export function createWorshipPanel({ showOnScreen, clearScreen, showMessage }) {
  const state = {
    songs: [],
    settings: {},
    song: null,
    arrangement: [],
    index: 0,
    onScreen: false,
  };

  const library = createLibraryDialog({
    onSongsChanged: (songs) => {
      state.songs = songs;
      $('song-find-list').replaceChildren(...songs.map((song) => el('option', { value: song.title })));
    },
    onLoadSong: (song) => loadSong(song),
    getSettings: () => state.settings,
    onSettingsChanged: (settings) => {
      state.settings = settings;
      refreshScreen();
    },
    showMessage,
  });

  function render() {
    const { song, arrangement, index } = state;
    $('song-now').hidden = !song;
    const flag = $('worship-state');
    flag.hidden = !song;
    flag.textContent = state.onScreen ? 'On screen' : 'Not on screen';
    flag.dataset.kind = state.onScreen ? 'live' : 'unsent';
    if (!song) return;

    const line = arrangement[index];
    $('song-title').textContent = song.title;
    $('song-current').textContent = line?.text ?? '';
    $('song-next').textContent = arrangement[index + 1]?.text ?? '(end of song)';
    $('line-prev').disabled = index <= 0;
    $('line-next').disabled = index >= arrangement.length - 1;
    $('lyrics-show').textContent = state.onScreen ? 'On Screen' : 'Show on screen';
    $('lyrics-show').disabled = state.onScreen;
    $('lyrics-blank').disabled = !state.onScreen;

    $('section-chips').replaceChildren(...sectionStops(arrangement).map((stop) => el('button', {
      type: 'button',
      class: 'chip',
      'aria-pressed': String(line?.orderIndex === arrangement[stop.index].orderIndex),
      on: { click: () => goTo(stop.index) },
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

  function loadSong(song) {
    state.song = song;
    state.arrangement = arrangementOf(song);
    state.index = 0;
    refreshScreen();
  }

  function closeSong() {
    if (state.onScreen) clearScreen();
    state.song = null;
    state.onScreen = false;
    render();
  }

  function findAndLoad(event) {
    event.preventDefault();
    const query = $('song-find-input').value.trim().toLowerCase();
    if (!query) return;
    const song = state.songs.find((s) => s.title.toLowerCase() === query)
      ?? state.songs.find((s) => s.title.toLowerCase().includes(query));
    if (!song) {
      showMessage('library', `No song called “${$('song-find-input').value}” in the library.`);
      return;
    }
    $('song-find-input').value = '';
    loadSong(song);
  }

  function bind() {
    library.bind();
    $('song-find').addEventListener('submit', findAndLoad);
    $('line-prev').addEventListener('click', () => goTo(state.index - 1));
    $('line-next').addEventListener('click', () => goTo(state.index + 1));
    $('lyrics-show').addEventListener('click', () => {
      state.onScreen = true;
      refreshScreen();
    });
    $('lyrics-blank').addEventListener('click', () => {
      state.onScreen = false;
      clearScreen();
      render();
    });
    $('song-close').addEventListener('click', closeSong);
  }

  return {
    async init() {
      bind();
      try {
        state.settings = await getLyricsSettings();
      } catch (error) {
        showMessage('library', `Couldn't load lyrics settings: ${error.message}`, { kind: 'error' });
      }
      await library.refresh();
      render();
    },
    // A Bible passage went on screen, or the operator cleared it.
    noteOtherContentShown() {
      state.onScreen = false;
      render();
    },
    noteBlanked() {
      state.onScreen = false;
      render();
    },
  };
}
