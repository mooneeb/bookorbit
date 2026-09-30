import { existsSync } from 'fs';
import { join } from 'path';
import { drizzle } from 'drizzle-orm/node-postgres';
import { migrate } from 'drizzle-orm/node-postgres/migrator';
import type { Pool } from 'pg';

import { FORK_MIGRATIONS_SCHEMA, FORK_MIGRATIONS_TABLE } from '../db/fork/fork-migrations.constants';

function resolveForkMigrationsFolder(): string {
  const candidates = [
    join(__dirname, '..', '..', 'fork-migrations'),
    join(__dirname, '..', 'db', 'fork', 'migrations'),
    join(process.cwd(), 'fork-migrations'),
    join(process.cwd(), 'src', 'db', 'fork', 'migrations'),
  ];

  const match = candidates.find((path) => existsSync(path));
  if (!match) {
    throw new Error(`Unable to locate fork migrations folder. Checked: ${candidates.join(', ')}`);
  }
  return match;
}

// Must run after the upstream set: fork tables reference upstream tables by foreign key.
export async function runForkMigrations(pool: Pool): Promise<void> {
  const migrationsFolder = resolveForkMigrationsFolder();
  await migrate(drizzle(pool), {
    migrationsFolder,
    migrationsTable: FORK_MIGRATIONS_TABLE,
    migrationsSchema: FORK_MIGRATIONS_SCHEMA,
  });
  console.log(`Fork migrations applied successfully from ${migrationsFolder}`);
}
