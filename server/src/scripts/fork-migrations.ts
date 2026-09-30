import { drizzle } from 'drizzle-orm/node-postgres';
import { migrate } from 'drizzle-orm/node-postgres/migrator';
import type { Pool } from 'pg';

import { FORK_MIGRATIONS_SCHEMA, FORK_MIGRATIONS_TABLE } from '../db/fork/fork-migrations.constants';
import { resolveMigrationsFolder } from './migrations-folder';

// Must run after the upstream set: fork tables reference upstream tables by foreign key.
export async function runForkMigrations(pool: Pool): Promise<void> {
  const migrationsFolder = resolveMigrationsFolder('fork-migrations', ['db', 'fork', 'migrations']);
  await migrate(drizzle(pool), {
    migrationsFolder,
    migrationsTable: FORK_MIGRATIONS_TABLE,
    migrationsSchema: FORK_MIGRATIONS_SCHEMA,
  });
  console.log(`Fork migrations applied successfully from ${migrationsFolder}`);
}
