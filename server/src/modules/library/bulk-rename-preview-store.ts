import { mkdtemp, rm } from 'fs/promises';
import { tmpdir } from 'os';
import { join } from 'path';
import { DatabaseSync } from 'node:sqlite';

import type { BulkRenamePreviewItem, BulkRenamePreviewPage, BulkRenameStatus } from '@bookorbit/types';

export interface IndexedRenameItem extends BulkRenamePreviewItem {
  targetFolder: string | null;
}

export class BulkRenamePreviewStore {
  readonly createdAt = Date.now();

  private constructor(
    private readonly directory: string,
    private readonly db: DatabaseSync,
    readonly pattern: string,
  ) {}

  static async create(pattern: string): Promise<BulkRenamePreviewStore> {
    const directory = await mkdtemp(join(tmpdir(), 'bookorbit-rename-'));
    const db = new DatabaseSync(join(directory, 'preview.sqlite'));
    db.exec(`
      PRAGMA cache_size = -2048;
      PRAGMA temp_store = FILE;
      CREATE TABLE items (bookId INTEGER PRIMARY KEY, title TEXT NOT NULL, currentPath TEXT NOT NULL,
        newPath TEXT, status TEXT NOT NULL, reason TEXT, targetFolder TEXT);
      CREATE INDEX items_status ON items(status, bookId);
      CREATE INDEX items_folder ON items(targetFolder);
      CREATE TABLE targets (path TEXT NOT NULL, bookId INTEGER NOT NULL, PRIMARY KEY(path, bookId));
    `);
    return new BulkRenamePreviewStore(directory, db, pattern);
  }

  addBatch(items: IndexedRenameItem[], targets: { path: string; bookId: number }[]): void {
    const insertItem = this.db.prepare('INSERT INTO items VALUES (?, ?, ?, ?, ?, ?, ?)');
    const insertTarget = this.db.prepare('INSERT OR IGNORE INTO targets VALUES (?, ?)');
    this.db.exec('BEGIN');
    try {
      for (const item of items) {
        insertItem.run(item.bookId, item.title, item.currentPath, item.newPath, item.status, item.reason ?? null, item.targetFolder);
      }
      for (const target of targets) insertTarget.run(target.path.toLowerCase(), target.bookId);
      this.db.exec('COMMIT');
    } catch (error) {
      this.db.exec('ROLLBACK');
      throw error;
    }
  }

  markCollision(bookId: number, reason: string): void {
    this.db.prepare("UPDATE items SET status = 'collision', reason = ? WHERE bookId = ? AND status = 'will_rename'").run(reason, bookId);
  }

  markSharedTargets(folderMode: boolean): void {
    this.db
      .prepare(
        `UPDATE items SET status = 'collision', reason = ? WHERE bookId IN
      (SELECT bookId FROM targets WHERE path IN (SELECT path FROM targets GROUP BY path HAVING COUNT(*) > 1))
      AND status IN ('will_rename', 'unchanged')`,
      )
      .run('Multiple books would resolve to the same path');
    if (folderMode) {
      this.db
        .prepare(
          `UPDATE items SET status = 'collision', reason = ? WHERE status = 'will_rename' AND targetFolder IN
        (SELECT targetFolder FROM items WHERE status = 'will_rename' AND targetFolder IS NOT NULL
         GROUP BY targetFolder HAVING COUNT(*) > 1)`,
        )
        .run('Multiple books would resolve to the same folder');
    }
  }

  getPage(page: number, pageSize: number, status?: BulkRenameStatus, search?: string): BulkRenamePreviewPage {
    const conditions: string[] = [];
    const params: string[] = [];
    if (status) {
      conditions.push('status = ?');
      params.push(status);
    }
    const query = search?.trim().toLowerCase();
    if (query) {
      conditions.push('(instr(lower(title), ?) > 0 OR instr(lower(currentPath), ?) > 0)');
      params.push(query, query);
    }
    const where = conditions.length ? `WHERE ${conditions.join(' AND ')}` : '';
    const count = this.db.prepare(`SELECT COUNT(*) AS total FROM items ${where}`).get(...params) as { total: number };
    const rows = this.db
      .prepare(
        `SELECT bookId, title, currentPath, newPath, status, reason FROM items ${where}
      ORDER BY bookId LIMIT ? OFFSET ?`,
      )
      .all(...params, pageSize, (page - 1) * pageSize);
    const totalByStatus: Record<BulkRenameStatus, number> = { will_rename: 0, unchanged: 0, collision: 0, no_pattern: 0, error: 0 };
    for (const row of this.db.prepare('SELECT status, COUNT(*) AS total FROM items GROUP BY status').all()) {
      totalByStatus[row.status as BulkRenameStatus] = row.total as number;
    }
    return { items: rows.map((row) => this.toItem(row)), total: count.total, totalByStatus, pattern: this.pattern };
  }

  candidateBatch(afterBookId: number, limit: number): BulkRenamePreviewItem[] {
    return this.db
      .prepare(
        "SELECT bookId, title, currentPath, newPath, status, reason FROM items WHERE status = 'will_rename' AND bookId > ? ORDER BY bookId LIMIT ?",
      )
      .all(afterBookId, limit)
      .map((row) => this.toItem(row));
  }

  private toItem(row: Record<string, unknown>): BulkRenamePreviewItem {
    return {
      bookId: row.bookId as number,
      title: row.title as string,
      currentPath: row.currentPath as string,
      newPath: row.newPath as string | null,
      status: row.status as BulkRenameStatus,
      ...(row.reason ? { reason: row.reason as string } : {}),
    };
  }

  async close(): Promise<void> {
    this.db.close();
    await rm(this.directory, { recursive: true, force: true });
  }
}
