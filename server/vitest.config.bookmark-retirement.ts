import path from 'node:path';
import { defineConfig } from 'vitest/config';

export default defineConfig({
  resolve: { tsconfigPaths: true, alias: { '@bookorbit/types': path.resolve(__dirname, '../packages/types/src/index.ts') } },
  test: {
    globals: true,
    environment: 'node',
    pool: 'forks',
    maxWorkers: 1,
    fileParallelism: false,
    setupFiles: ['test/e2e.setup.ts'],
    include: ['test/ipad/bookmark-retirement.http.test.ts'],
    testTimeout: 120_000,
    hookTimeout: 120_000,
  },
});
