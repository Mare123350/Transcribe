// The song library screen: search, create, edit, delete and import.
import { createSong, deleteSong, listSongs, updateLyricsSettings, updateSong } from '/js/api.js';
import { matchesSearch, parseOpenLyrics, parsePlainTextSong, validateSong } from '/shared/lyrics/songs.js';
import { el } from '/js/lyrics/dom.js';

const $ = (id) => document.getElementById(id);

export function createLibraryDialog({ onSongsChanged, onLoadSong, getSettings, onSettingsChanged, showMessage }) {
  let songs = [];
  let selected = null; // the song being edited; { isNew: true } while creating one

  const showError = (text) => {
    $('song-editor-error').textContent = text ?? '';
    $('song-editor-error').hidden = !text;
  };

  function renderList() {
    const query = $('library-search').value;
    const visible = songs.filter((song) => matchesSearch(song, query));
    const list = $('library-list');
    if (!visible.length) {
      list.replaceChildren(el('li', { class: 'empty song-editor-empty' }, songs.length ? 'No songs match that search.' : 'No songs yet.'));
      return;
    }
    list.replaceChildren(...visible.map((song) => el('li', {},
      el('button', {
        type: 'button',
        'aria-current': String(selected?.id === song.id),
        on: { click: () => edit(song) },
      }, song.title, el('small', {}, song.artist || 'Unknown artist')))));
  }

  function edit(song) {
    selected = song;
    showError(null);
    $('song-editor').hidden = false;
    $('song-editor-empty').hidden = true;
    $('song-field-title').value = song.title ?? '';
    $('song-field-artist').value = song.artist ?? '';
    $('song-field-language').value = song.language ?? 'en';
    $('song-field-ccli').value = song.ccli ?? '';
    $('song-field-order').value = (song.order ?? []).join(' ');
    $('song-field-lyrics').value = (song.sections ?? [])
      .map((section) => `[${section.label}]\n${section.lines.join('\n')}`)
      .join('\n\n');
    $('song-delete').hidden = Boolean(song.isNew);
    $('song-load').hidden = Boolean(song.isNew);
    renderList();
  }

  // Reads the form. The lyrics box accepts a whole pasted song, including Title: and Order: headers.
  function readForm() {
    const parsed = parsePlainTextSong($('song-field-lyrics').value);
    const order = $('song-field-order').value.trim();
    return {
      title: $('song-field-title').value.trim() || parsed.title,
      artist: $('song-field-artist').value.trim() || parsed.artist,
      language: $('song-field-language').value.trim() || parsed.language,
      ccli: $('song-field-ccli').value.trim() || parsed.ccli,
      order: order ? order.toLowerCase().split(/[\s,]+/) : parsed.order,
      sections: parsed.sections,
    };
  }

  async function refresh() {
    try {
      songs = await listSongs();
      onSongsChanged(songs);
      renderList();
    } catch (error) {
      showMessage('library', `Couldn't load the song library: ${error.message}`, { kind: 'error' });
    }
    return songs;
  }

  async function save(event) {
    event.preventDefault();
    const song = readForm();
    const problems = validateSong(song);
    if (problems.length) {
      showError(problems.join(' '));
      return;
    }
    try {
      const saved = selected?.isNew ? await createSong(song) : await updateSong(selected.id, song);
      await refresh();
      edit(saved);
    } catch (error) {
      showError(error.message);
    }
  }

  async function remove() {
    if (!selected || selected.isNew) return;
    if (!window.confirm(`Delete “${selected.title}” from the library?`)) return;
    try {
      await deleteSong(selected.id);
      selected = null;
      $('song-editor').hidden = true;
      $('song-editor-empty').hidden = false;
      await refresh();
    } catch (error) {
      showError(error.message);
    }
  }

  async function importFiles(files) {
    const failures = [];
    let added = 0;
    for (const file of files) {
      try {
        const text = await file.text();
        const song = /<song[\s>]/i.test(text) ? parseOpenLyrics(text) : parsePlainTextSong(text);
        if (!song.title) song.title = file.name.replace(/\.[^.]+$/, '');
        const problems = validateSong(song);
        if (problems.length) throw new Error(problems.join(' '));
        await createSong(song);
        added++;
      } catch (error) {
        failures.push(`${file.name}: ${error.message}`);
      }
    }
    await refresh();
    if (failures.length) showError(`Imported ${added}. Couldn't import ${failures.join('; ')}`);
    else {
      showError(null);
      showMessage('library', `Imported ${added} song${added === 1 ? '' : 's'}.`);
    }
    if (failures.length) {
      $('song-editor').hidden = false;
      $('song-editor-empty').hidden = true;
    }
  }

  function renderSettings() {
    const settings = getSettings();
    $('setting-license').value = settings.ccliLicense ?? '';
    $('setting-lines').value = String(settings.linesPerScreen ?? 2);
    $('setting-credit').checked = settings.showCredit !== false;
    $('setting-highlight').checked = settings.highlightCurrent !== false;
  }

  async function saveSettings() {
    try {
      onSettingsChanged(await updateLyricsSettings({
        ccliLicense: $('setting-license').value.trim(),
        linesPerScreen: Number($('setting-lines').value),
        showCredit: $('setting-credit').checked,
        highlightCurrent: $('setting-highlight').checked,
      }));
    } catch (error) {
      showMessage('library', `Couldn't save those settings: ${error.message}`, { kind: 'error' });
    }
  }

  function bind() {
    $('open-library').addEventListener('click', () => {
      renderSettings();
      refresh();
      $('library').showModal();
    });
    $('library-close').addEventListener('click', () => $('library').close());
    $('library-search').addEventListener('input', renderList);
    $('song-new').addEventListener('click', () => edit({ isNew: true, title: '', artist: '', language: 'en', ccli: '', order: [], sections: [] }));
    $('song-editor').addEventListener('submit', save);
    $('song-delete').addEventListener('click', remove);
    $('song-load').addEventListener('click', () => {
      if (!selected || selected.isNew) return;
      onLoadSong(selected);
      $('library').close();
    });
    $('song-import').addEventListener('change', async (event) => {
      await importFiles([...event.target.files]);
      event.target.value = '';
    });
    for (const id of ['setting-license', 'setting-lines', 'setting-credit', 'setting-highlight']) {
      $(id).addEventListener('change', saveSettings);
    }
  }

  return { bind, refresh };
}

