import type { Config } from 'drizzle-kit';

import { FORK_MIGRATIONS_SCHEMA, FORK_MIGRATIONS_TABLE } from './src/db/fork/fork-migrations.constants';

// Fork-only tables keep their own schema entry, folder and ledger so upstream merges never
// interleave with them (docs/adr/0003-fork-only-tables-with-separate-migrations.md).
export default {
  schema: './src/db/fork/schema/index.ts',
  out: './src/db/fork/migrations',
  dialect: 'postgresql',
  migrations: {
    table: FORK_MIGRATIONS_TABLE,
    schema: FORK_MIGRATIONS_SCHEMA,
  },
  dbCredentials: {
    url: process.env.DATABASE_URL ?? 'postgres://bookorbit:bookorbit@postgres:5432/bookorbit',
  },
} satisfies Config;
