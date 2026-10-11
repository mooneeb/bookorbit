import { PgDialect } from 'drizzle-orm/pg-core';
import { describe, expect, it, vi } from 'vitest';

import { bookCustomMetadataValues } from '../../db/schema';
import { CustomMetadataRepository } from './custom-metadata.repository';

describe('CustomMetadataRepository bulk values', () => {
  it('bounds 10,000 selected book values to 500-row writes in the supplied transaction', async () => {
    const onConflictDoUpdate = vi.fn().mockResolvedValue(undefined);
    const values = vi.fn().mockReturnValue({ onConflictDoUpdate });
    const tx = { insert: vi.fn().mockReturnValue({ values }) };
    const db = { insert: vi.fn() };
    const repository = new CustomMetadataRepository(db as never);

    await repository.writeValuesForBooks(
      Array.from({ length: 100 }, (_, index) => index + 1),
      Array.from({ length: 100 }, (_, index) => ({
        fieldId: index + 1,
        value: { valueText: null, valueNumber: 0, valueDate: null, valueBoolean: null },
      })),
      tx as never,
    );

    expect(values).toHaveBeenCalledTimes(20);
    expect(values.mock.calls.every(([rows]) => rows.length === 500)).toBe(true);
    expect(values.mock.calls.flatMap(([rows]) => rows)).toHaveLength(10_000);
    expect(tx.insert).toHaveBeenCalledWith(bookCustomMetadataValues);
    expect(db.insert).not.toHaveBeenCalled();
    const conflict = onConflictDoUpdate.mock.calls[0][0];
    expect(conflict.target).toEqual([bookCustomMetadataValues.bookId, bookCustomMetadataValues.fieldId]);
    expect(Object.keys(conflict.set)).toEqual(['valueText', 'valueNumber', 'valueDate', 'valueBoolean', 'updatedAt']);
  });

  it('clears only requested null fields for selected books and preserves the last repeated field value', async () => {
    const where = vi.fn().mockResolvedValue(undefined);
    const onConflictDoUpdate = vi.fn().mockResolvedValue(undefined);
    const values = vi.fn().mockReturnValue({ onConflictDoUpdate });
    const tx = { delete: vi.fn().mockReturnValue({ where }), insert: vi.fn().mockReturnValue({ values }) };
    const repository = new CustomMetadataRepository({} as never);

    await repository.writeValuesForBooks(
      [5, 9, 5],
      [
        { fieldId: 7, value: { valueBoolean: true } },
        { fieldId: 7, value: null },
        { fieldId: 8, value: { valueText: null, valueNumber: null, valueDate: null, valueBoolean: false } },
      ],
      tx as never,
    );

    expect(new PgDialect().sqlToQuery(where.mock.calls[0][0]).params).toEqual([5, 9, 7]);
    expect(values).toHaveBeenCalledWith([
      expect.objectContaining({ bookId: 5, fieldId: 8, valueBoolean: false }),
      expect.objectContaining({ bookId: 9, fieldId: 8, valueBoolean: false }),
    ]);
  });
});
