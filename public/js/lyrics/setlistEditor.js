// The Setlists tab of the library screen.
import { createSetlist, deleteSetlist, listSetlists, updateSetlist } from '/js/api.js';
import { el } from '/js/lyrics/dom.js';

const $ = (id) => document.getElementById(id);

export function createSetlistEditor({ getSongs, getActiveId, onUse, onChanged }) {
  let setlists = [];
  let draft = null;

  const showError = (text) => {
    $('setlist-error').textContent = text ?? '';
    $('setlist-error').hidden = !text;
  };

  const songById = (id) => getSongs().find((song) => song.id === id);

  function renderList() {
    if (!setlists.length) {
      $('setlist-list').replaceChildren(el('li', { class: 'empty song-editor-empty' }, 'No setlists yet.'));
      return;
    }
    $('setlist-list').replaceChildren(...setlists.map((setlist) => el('li', {},
      el('button', { type: 'button', 'aria-current': String(draft?.id === setlist.id), on: { click: () => edit(setlist) } },
        setlist.name,
        el('small', {}, [setlist.date, `${setlist.songIds.length} songs`, setlist.id === getActiveId() ? 'Active' : ''].filter(Boolean).join(' · '))))));
  }

  function moveSong(index, direction) {
    const target = index + direction;
    if (target < 0 || target >= draft.songIds.length) return;
    [draft.songIds[index], draft.songIds[target]] = [draft.songIds[target], draft.songIds[index]];
    renderItems();
  }

  function renderItems() {
    $('setlist-items').replaceChildren(...draft.songIds.map((id, index) => el('li', {},
      el('span', {}, `${index + 1}. ${songById(id)?.title ?? 'Song not in the library'}`),
      el('button', { type: 'button', class: 'button', 'aria-label': 'Move up', disabled: index === 0, on: { click: () => moveSong(index, -1) } }, '↑'),
      el('button', { type: 'button', class: 'button', 'aria-label': 'Move down', disabled: index === draft.songIds.length - 1, on: { click: () => moveSong(index, 1) } }, '↓'),
      el('button', { type: 'button', class: 'link', on: { click: () => { draft.songIds.splice(index, 1); renderItems(); } } }, 'Remove'))));
    if (!draft.songIds.length) $('setlist-items').append(el('li', { class: 'empty' }, 'No songs yet.'));
  }

  function edit(setlist) {
    draft = { ...setlist, songIds: [...setlist.songIds] };
    showError(null);
    $('setlist-editor').hidden = false;
    $('setlist-empty').hidden = true;
    $('setlist-name').value = draft.name;
    $('setlist-date').value = draft.date;
    $('setlist-delete').hidden = !draft.id;
    $('setlist-use').hidden = !draft.id;
    renderItems();
    renderList();
  }

  function addSong() {
    const query = $('setlist-add-input').value.trim().toLowerCase();
    if (!query) return;
    const song = getSongs().find((s) => s.title.toLowerCase() === query)
      ?? getSongs().find((s) => s.title.toLowerCase().includes(query));
    if (!song) {
      showError(`No song called “${$('setlist-add-input').value}” in the library.`);
      return;
    }
    showError(null);
    draft.songIds.push(song.id);
    $('setlist-add-input').value = '';
    renderItems();
  }

  async function refresh() {
    setlists = await listSetlists();
    renderList();
    onChanged(setlists);
    return setlists;
  }

  async function save(event) {
    event.preventDefault();
    const body = { name: $('setlist-name').value, date: $('setlist-date').value, songIds: draft.songIds };
    try {
      const saved = draft.id ? await updateSetlist(draft.id, body) : await createSetlist(body);
      await refresh();
      edit(saved);
    } catch (error) {
      showError(error.message);
    }
  }

  async function remove() {
    if (!draft?.id || !window.confirm(`Delete the setlist “${draft.name}”? The songs stay in the library.`)) return;
    try {
      await deleteSetlist(draft.id);
      draft = null;
      $('setlist-editor').hidden = true;
      $('setlist-empty').hidden = false;
      await refresh();
    } catch (error) {
      showError(error.message);
    }
  }

  function bind() {
    const selectTab = (songsTab) => {
      $('songs-pane').hidden = !songsTab;
      $('setlists-pane').hidden = songsTab;
      for (const [id, on] of [['tab-songs', songsTab], ['tab-setlists', !songsTab]]) {
        $(id).setAttribute('aria-selected', String(on));
        $(id).setAttribute('aria-checked', String(on));
      }
    };
    $('tab-songs').addEventListener('click', () => selectTab(true));
    $('tab-setlists').addEventListener('click', () => selectTab(false));
    $('setlist-new').addEventListener('click', () => edit({ name: '', date: new Date().toISOString().slice(0, 10), songIds: [] }));
    $('setlist-editor').addEventListener('submit', save);
    $('setlist-add').addEventListener('click', addSong);
    $('setlist-add-input').addEventListener('keydown', (event) => {
      if (event.key === 'Enter') {
        event.preventDefault();
        addSong();
      }
    });
    $('setlist-delete').addEventListener('click', remove);
    $('setlist-use').addEventListener('click', async () => {
      if (!draft?.id) return;
      await onUse(draft.id);
      renderList();
    });
  }

  return { bind, refresh };
}
