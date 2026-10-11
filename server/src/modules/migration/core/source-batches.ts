import type { SourceExportData } from '../adapters/source-adapter.types';

const BOOK_BATCH_SIZE = 100;
const ENTITY_BATCH_SIZE = 500;
const BOOK_DOMAINS = ['userBookStatuses', 'userFileProgress', 'readingSessions', 'bookmarks', 'annotations', 'shelfBooks'] as const;

export function* boundedSourceBatches(source: SourceExportData): Generator<{ sourceData: SourceExportData; bookOverlays: boolean }> {
  const populatedShelfIds = new Set(source.shelfBooks.map((row) => row.sourceShelfId));
  const sourceBookIds = new Set(source.books.map((book) => book.sourceBookId));
  const groupCount = Math.max(1, Math.ceil(source.books.length / BOOK_BATCH_SIZE));
  for (let group = 0; group <= groupCount; group += 1) {
    const orphanGroup = group === groupCount;
    const books = source.books.slice(group * BOOK_BATCH_SIZE, (group + 1) * BOOK_BATCH_SIZE);
    const bookIds = new Set(books.map((book) => book.sourceBookId));
    const domains = Object.fromEntries(
      BOOK_DOMAINS.map((key) => [
        key,
        (source[key] ?? []).filter((row) => (orphanGroup ? !sourceBookIds.has(row.sourceBookId) : bookIds.has(row.sourceBookId))),
      ]),
    ) as Pick<SourceExportData, (typeof BOOK_DOMAINS)[number]>;
    if (orphanGroup && BOOK_DOMAINS.every((key) => domains[key].length === 0)) continue;
    const relevantShelfIds = new Set(domains.shelfBooks.map((row) => row.sourceShelfId));
    const shelves = source.shelves.filter(
      (shelf) => relevantShelfIds.has(shelf.sourceShelfId) || (group === 0 && !populatedShelfIds.has(shelf.sourceShelfId)),
    );
    const pageCount = Math.max(1, Math.ceil(Math.max(shelves.length, ...BOOK_DOMAINS.map((key) => domains[key].length)) / ENTITY_BATCH_SIZE));
    for (let page = 0; page < pageCount; page += 1) {
      const start = page * ENTITY_BATCH_SIZE;
      const data = Object.fromEntries(BOOK_DOMAINS.map((key) => [key, domains[key].slice(start, start + ENTITY_BATCH_SIZE)])) as Pick<
        SourceExportData,
        (typeof BOOK_DOMAINS)[number]
      >;
      const pageShelfIds = new Set(data.shelfBooks.map((row) => row.sourceShelfId));
      const pageShelves = shelves.filter(
        (shelf, index) => pageShelfIds.has(shelf.sourceShelfId) || (index >= start && index < start + ENTITY_BATCH_SIZE),
      );
      const userIds = new Set([
        ...BOOK_DOMAINS.flatMap((key) => data[key].map((row) => row.sourceUserId)),
        ...pageShelves.map((shelf) => shelf.sourceUserId),
      ]);
      yield {
        sourceData: {
          ...data,
          users: source.users.filter((user) => userIds.has(user.sourceUserId)),
          books,
          shelves: pageShelves,
          availableDomains: source.availableDomains,
        },
        bookOverlays: !orphanGroup && source.bookOverlays !== false && page === 0,
      };
    }
  }
}
