// Talks to our own server. Failures come back as ApiError with a message fit to show the operator.
export class ApiError extends Error {
  constructor(code, message) {
    super(message);
    this.code = code;
  }
}

async function request(path, options) {
  let response;
  try {
    response = await fetch(path, options);
  } catch {
    throw new ApiError('network', "Can't reach the Transcribe server. Is it still running?");
  }
  if (response.status === 204) return null;
  const body = await response.json().catch(() => null);
  if (!response.ok) throw new ApiError(body?.error?.code ?? 'server', body?.error?.message ?? `Server error (${response.status}).`);
  return body;
}

const post = (path, body) => request(path, {
  method: 'POST',
  headers: { 'content-type': 'application/json' },
  body: JSON.stringify(body),
});

export const getConfig = () => request('/api/config');
export const getVersification = (id) => request(`/api/translations/${encodeURIComponent(id)}/versification`);
export const getPassage = (refKey, translationId) => request(`/api/passage?ref=${encodeURIComponent(refKey)}&translation=${encodeURIComponent(translationId)}`);
export const publishDisplay = (state) => post('/api/display', state);
export const saveTranscript = (text) => post('/api/transcripts', { text });

const send = (method, path, body) => request(path, {
  method,
  headers: { 'content-type': 'application/json' },
  body: body === undefined ? undefined : JSON.stringify(body),
});

export const listSongs = () => request('/api/songs');
export const createSong = (song) => send('POST', '/api/songs', song);
export const updateSong = (id, song) => send('PUT', `/api/songs/${encodeURIComponent(id)}`, song);
export const deleteSong = (id) => send('DELETE', `/api/songs/${encodeURIComponent(id)}`);
export const getLyricsSettings = () => request('/api/lyrics-settings');
export const updateLyricsSettings = (patch) => send('PUT', '/api/lyrics-settings', patch);
export const listSetlists = () => request('/api/setlists');
export const createSetlist = (setlist) => send('POST', '/api/setlists', setlist);
export const updateSetlist = (id, setlist) => send('PUT', `/api/setlists/${encodeURIComponent(id)}`, setlist);
export const deleteSetlist = (id) => send('DELETE', `/api/setlists/${encodeURIComponent(id)}`);
