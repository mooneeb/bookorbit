import { existsSync } from 'node:fs';
import { mkdir, writeFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { createServer } from 'node:net';
import { setTimeout } from 'node:timers/promises';
import {
  createReaderStateIsolationE2EContext,
  closeReaderStateIsolationE2EContext,
} from './e2e/reader-state-isolation/reader-state-isolation-harness';
import { prepareNativeQA } from './e2e/native-reader/native-reader-qa';

describe.skipIf(process.env.NATIVE_QA_SESSION !== '1')('Isolated visible native QA deployment', () => {
  it(
    'serves generated fixtures until the operator finishes verification',
    async () => {
      const output = resolve(process.env.NATIVE_QA_OUTPUT ?? '../native/build/qa-session');
      const ctx = await createReaderStateIsolationE2EContext();
      const link = createServer((socket) => {
        const chunk = Buffer.alloc(64 * 1024, 42);
        let remaining = 512;
        socket.setTimeout(10_000, () => socket.destroy());
        const send = () => {
          while (remaining > 0) {
            remaining--;
            if (!socket.write(chunk)) return;
          }
          socket.end();
        };
        socket.on('error', () => socket.destroy());
        socket.on('drain', send);
        send();
      });
      link.maxConnections = 1;
      try {
        const large = process.env.NATIVE_QA_LARGE !== '0';
        const qa = await prepareNativeQA(ctx, large);
        if (process.env.NATIVE_QA_LINK_PROBE === '1')
          await new Promise<void>((accept, reject) => {
            link.once('error', reject);
            link.listen(55459, process.env.NATIVE_QA_BIND ?? '127.0.0.1', accept);
          });
        await ctx.app.listen(55458, process.env.NATIVE_QA_BIND ?? '127.0.0.1');
        await mkdir(output, { recursive: true });
        await writeFile(
          resolve(output, 'ready.json'),
          JSON.stringify({
            files: qa.files,
            accountId: qa.owner.userId,
            books: large ? 50_000 : Object.keys(qa.files).length - 1,
            annotations: large ? 100_000 : 0,
            storage: process.env.NATIVE_QA_TMPFS === '1' ? 'tmpfs' : 'disk',
          }),
        );
        console.log(`[native.qa_session] [start] large=${large} - isolated deployment ready`);
        const deadline = Date.now() + 45 * 60_000;
        while (!existsSync(resolve(output, 'stop')) && Date.now() < deadline) await setTimeout(250);
        console.log('[native.qa_session] [end] - isolated deployment stopped');
      } finally {
        link.close();
        await closeReaderStateIsolationE2EContext(ctx);
      }
    },
    46 * 60_000,
  );
});
