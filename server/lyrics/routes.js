import express from 'express';
import { NotFoundError, ValidationError } from './store.js';

export function createLyricsRouter(store) {
  const router = express.Router();

  router.get('/songs', async (_request, response) => response.json(await store.listSongs()));
  router.post('/songs', async (request, response) => response.status(201).json(await store.createSong(request.body)));
  router.put('/songs/:id', async (request, response) => response.json(await store.updateSong(request.params.id, request.body)));
  router.delete('/songs/:id', async (request, response) => {
    await store.deleteSong(request.params.id);
    response.status(204).end();
  });

  router.get('/setlists', async (_request, response) => response.json(await store.listSetlists()));
  router.post('/setlists', async (request, response) => response.status(201).json(await store.createSetlist(request.body)));
  router.put('/setlists/:id', async (request, response) => response.json(await store.updateSetlist(request.params.id, request.body)));
  router.delete('/setlists/:id', async (request, response) => {
    await store.deleteSetlist(request.params.id);
    response.status(204).end();
  });

  router.get('/lyrics-settings', async (_request, response) => response.json(await store.getSettings()));
  router.put('/lyrics-settings', async (request, response) => response.json(await store.updateSettings(request.body)));

  router.get('/lyrics-export', async (_request, response) => {
    response.set('Content-Disposition', 'attachment; filename="transcribe-lyrics-library.json"');
    response.json(await store.exportAll());
  });

  router.use((error, _request, response, next) => {
    if (response.headersSent) return next(error);
    if (error instanceof ValidationError) return response.status(400).json({ error: { code: 'invalid', message: error.message } });
    if (error instanceof NotFoundError) return response.status(404).json({ error: { code: 'not_found', message: error.message } });
    next(error);
  });
  return router;
}
