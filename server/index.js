import { createApp } from './app.js';

const host = process.env.HOST ?? '127.0.0.1';
const port = Number(process.env.PORT ?? 3000);

const { server, bible } = await createApp();

server.on('error', (error) => {
  if (error.code === 'EADDRINUSE') console.error(`Port ${port} is already in use. Set PORT in .env to use another one.`);
  else console.error(error);
  process.exit(1);
});

server.listen(port, host, () => {
  const shown = host === '0.0.0.0' || host === '::' ? 'localhost' : host;
  const ready = bible.listing().filter((t) => t.available).map((t) => t.abbreviation).join(', ');
  console.log(`
  Transcribe is running.

  Operator:     http://${shown}:${port}/
  Congregation: http://${shown}:${port}/display

  Translations ready: ${ready}
  Deepgram: ${process.env.DEEPGRAM_API_KEY ? 'configured' : 'not configured (browser speech recognition and demo mode still work)'}
`);
});
