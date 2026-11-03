import { appendFile, mkdir } from 'node:fs/promises';
import { join } from 'node:path';

// Only used when the operator turns on "Save transcripts". Writes text, one dated file per day.
// Audio is never written anywhere.
export function createTranscriptStore(directory) {
  return {
    directory,
    async append(text, date = new Date()) {
      await mkdir(directory, { recursive: true });
      const day = date.toISOString().slice(0, 10);
      const time = date.toTimeString().slice(0, 8);
      await appendFile(join(directory, `${day}.txt`), `[${time}] ${text.replace(/\s+/g, ' ').trim()}\n`);
    },
  };
}
