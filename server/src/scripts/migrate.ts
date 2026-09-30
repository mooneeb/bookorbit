import { readMigrationFiles } from 'drizzle-orm/migrator';
import { drizzle } from 'drizzle-orm/node-postgres';
import { migrate } from 'drizzle-orm/node-postgres/migrator';
import { Pool } from 'pg';

import { createPostgresClientConfig } from '../db/postgres-connection-config';
import { runForkMigrations } from './fork-migrations';
import { resolveMigrationsFolder } from './migrations-folder';
import { reconcileMigrationLedgerTimestamps } from './migration-ledger-compatibility';
import { installPostgresExtensions } from './postgres-extensions';
import { prepareLegacySeriesIndexColumns } from './series-index-migration-compatibility';

async function runMigrations() {
  const connectionString = process.env.DATABASE_URL;
  if (!connectionString) {
    throw new Error('DATABASE_URL is required');
  }

  const pool = new Pool(
    createPostgresClientConfig(connectionString, {
      max: 3,
      idleTimeoutMillis: 10_000,
      connectionTimeoutMillis: 5_000,
    }),
  );

  try {
    await installPostgresExtensions(pool);
    const migrationsFolder = resolveMigrationsFolder('migrations', ['db', 'migrations']);
    await reconcileMigrationLedgerTimestamps(pool, readMigrationFiles({ migrationsFolder }));
    await prepareLegacySeriesIndexColumns(pool);

    await migrate(drizzle(pool), { migrationsFolder });

    console.log(`Migrations applied successfully from ${migrationsFolder}`);

    await runForkMigrations(pool);
  } finally {
    await pool.end();
  }
}

void runMigrations();
