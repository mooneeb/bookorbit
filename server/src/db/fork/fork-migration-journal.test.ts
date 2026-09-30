import { existsSync, readdirSync, readFileSync } from 'node:fs';
import { basename, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { getTableName, is } from 'drizzle-orm';
import { PgTable } from 'drizzle-orm/pg-core';

import forkDrizzleConfig from '../../../drizzle.fork.config';
import upstreamDrizzleConfig from '../../../drizzle.config';
import * as forkSchema from './schema';
import * as upstreamSchema from '../schema';

type MigrationJournal = {
  entries: { idx: number; when: number; tag: string }[];
};

const serverRoot = fileURLToPath(new URL('../../../', import.meta.url));
const upstreamMigrationsDir = fileURLToPath(new URL('../migrations/', import.meta.url));
const forkMigrationsDir = fileURLToPath(new URL('./migrations/', import.meta.url));

function readJournal(dir: string): MigrationJournal {
  return JSON.parse(readFileSync(resolve(dir, 'meta/_journal.json'), 'utf8')) as MigrationJournal;
}

function tableNames(schema: Record<string, unknown>): string[] {
  return Object.values(schema)
    .filter((value): value is PgTable => is(value, PgTable))
    .map((table) => getTableName(table));
}

function sqlFiles(dir: string): string[] {
  return readdirSync(dir).filter((file) => file.endsWith('.sql'));
}

describe('Fork migration set', () => {
  const forkTables = tableNames(forkSchema);

  it('defines the fork tables', () => {
    expect(forkTables.sort()).toEqual(['fork_ink', 'fork_ipad_annotations']);
  });

  it('uses its own schema entry, migrations folder and migrations table', () => {
    expect(forkDrizzleConfig.schema).not.toEqual(upstreamDrizzleConfig.schema);
    expect(resolve(serverRoot, forkDrizzleConfig.out)).toBe(resolve(forkMigrationsDir));
    expect(resolve(serverRoot, forkDrizzleConfig.out)).not.toBe(resolve(serverRoot, upstreamDrizzleConfig.out));
    expect(forkDrizzleConfig.migrations?.table).toBeDefined();
    expect(forkDrizzleConfig.migrations?.table).not.toBe('__drizzle_migrations');
  });

  it('keeps its own journal in sync with its SQL files and strictly increasing timestamps', () => {
    const journal = readJournal(forkMigrationsDir);
    expect(journal.entries.length).toBeGreaterThan(0);

    journal.entries.forEach((entry, i) => {
      const prefix = i.toString().padStart(4, '0');
      expect(entry.idx).toBe(i);
      expect(entry.tag.startsWith(`${prefix}_`)).toBe(true);
      expect(existsSync(resolve(forkMigrationsDir, `meta/${prefix}_snapshot.json`))).toBe(true);
      if (i > 0) expect(entry.when).toBeGreaterThan(journal.entries[i - 1].when);
    });

    const fileTags = sqlFiles(forkMigrationsDir)
      .map((file) => basename(file, '.sql'))
      .sort();
    expect(journal.entries.map((entry) => entry.tag)).toEqual(fileTags);
  });

  it('shares no migration with the upstream journal', () => {
    const upstreamTags = new Set(readJournal(upstreamMigrationsDir).entries.map((entry) => entry.tag));
    for (const entry of readJournal(forkMigrationsDir).entries) {
      expect(upstreamTags.has(entry.tag), `${entry.tag} also appears in the upstream journal`).toBe(false);
    }
  });

  it('keeps fork tables out of the upstream schema entry', () => {
    const upstreamTables = new Set(tableNames(upstreamSchema));
    for (const table of forkTables) {
      expect(upstreamTables.has(table), `${table} is exported from the upstream schema`).toBe(false);
    }
  });

  it('never references a fork table from an upstream migration', () => {
    for (const file of sqlFiles(upstreamMigrationsDir)) {
      const content = readFileSync(resolve(upstreamMigrationsDir, file), 'utf8');
      for (const table of forkTables) {
        expect(content.includes(table), `${file} references fork table ${table}`).toBe(false);
      }
    }
  });
});
