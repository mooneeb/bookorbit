import { readFile, writeFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { count, eq, sql } from 'drizzle-orm';
import { Permission } from '@bookorbit/types';
import sharp from 'sharp';
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
  const pixels = Buffer.alloc(96 * 96 * 3);
  for (let y = 0; y < 96; y++)
    for (let x = 0; x < 96; x++) {
      const moon = (x - 42) ** 2 + (y - 48) ** 2 < 32 ** 2 && (x - 57) ** 2 + (y - 38) ** 2 >= 28 ** 2;
      pixels.set(moon ? [245, 240, 210] : [25, 35, 65], (y * 96 + x) * 3);
    }
  const image = await sharp(pixels, { raw: { width: 96, height: 96, channels: 3 } })
    .png()
    .toBuffer();
  const files: Record<string, Awaited<ReturnType<typeof locateBookByAbsolutePath>>> = {};
  const paths = new Map<string, string>();
  const titles = [
    'QA Prose',
    'QA Broken',
    'QA Hostile',
    'QA Traversal',
    'QA Fixed',
    'QA EPUB2',
    'QA Broken Srcset',
    'QA Broken Style',
    'QA Broken Import',
    'QA Embedded',
    'QA Media',
    'QA Vertical',
    'QA Mixed',
    'QA Nodes',
    'B Secret',
  ];
  const embeddedImage = await sharp({ create: { width: 9000, height: 2000, channels: 3, background: '#ffffff' } })
    .png()
    .toBuffer();
  for (const title of titles) {
    const target = title === 'B Secret' ? secret : library;
    const epub2 = title === 'QA EPUB2';
    const navigation = epub2 ? '<item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>' : '';
    const toc = epub2 ? ' toc="ncx"' : '';
    const fontType = epub2 ? 'application/vnd.ms-opentype' : 'font/ttf';
    const fixed = title === 'QA Fixed' ? '<meta property="rendition:layout">pre-paginated</meta>' : '';
    const spineProperty = title === 'QA Mixed' ? ' properties="rendition:layout-pre-paginated"' : '';
    const hostile =
      title === 'QA Hostile'
        ? '<script>document.body.textContent="ATTACK";fetch("http://127.0.0.1:55460/script");window.webkit.messageHandlers.reader.postMessage({kind:"ready"})</script><img src="http://127.0.0.1:55460/pixel" alt="Blocked remote image"/>'
        : '';
    const fault =
      title === 'QA Broken Srcset'
        ? '<img srcset="missing.png 1x" alt="Missing"/>'
        : title === 'QA Broken Style'
          ? '<p style="background-image:url(missing.png)">Missing image</p>'
          : title === 'QA Broken Import'
            ? '<style>@import "missing.css";</style>'
            : title === 'QA Embedded'
              ? `<img src="data:image/png;base64,${embeddedImage.toString('base64')}" alt="Oversized"/>`
              : title === 'QA Media'
                ? '<audio/>'
                : title === 'QA Vertical'
                  ? '<style>body{writing-mode:vertical-rl}</style>'
                  : title === 'QA Nodes'
                    ? '<b>word</b>'.repeat(50010)
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
        content: `<package xmlns="http://www.idpf.org/2007/opf" version="${epub2 ? '2.0' : '3.0'}" unique-identifier="id"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="id">qa-${title}</dc:identifier><dc:title>${title}</dc:title><dc:language>en</dc:language>${fixed}</metadata><manifest><item id="one" href="one.xhtml" media-type="application/xhtml+xml"/><item id="two" href="two.xhtml" media-type="application/xhtml+xml"/><item id="image" href="image.png" media-type="image/png"/><item id="font" href="font.ttf" media-type="${fontType}"/>${navigation}</manifest><spine${toc}><itemref idref="one"${spineProperty}/><itemref idref="two"/></spine></package>`,
      },
      {
        path: 'one.xhtml',
        content: `<html xmlns="http://www.w3.org/1999/xhtml"><head><title>One</title><meta name="viewport" content="width=800,height=1000"/><style>@font-face{font-family:QA;src:url('font.ttf')}p{font-family:QA}</style></head><body><h1>Chapter One</h1><p>The moon keeps its own time.</p><img src="image.png" alt="Moon"/>${hostile}${fault}</body></html>`,
      },
      {
        path: 'two.xhtml',
        content:
          '<html xmlns="http://www.w3.org/1999/xhtml"><head><title>Two</title><meta name="viewport" content="width=800,height=1000"/></head><body><h1>Chapter Two</h1></body></html>',
      },
      { path: 'font.ttf', content: font },
      ...(epub2
        ? [
            {
              path: 'toc.ncx',
              content:
                '<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1"><head><meta name="dtb:uid" content="qa-QA EPUB2"/><meta name="dtb:depth" content="1"/><meta name="dtb:totalPageCount" content="0"/><meta name="dtb:maxPageNumber" content="0"/></head><docTitle><text>QA EPUB2</text></docTitle><navMap><navPoint id="one" playOrder="1"><navLabel><text>Chapter One</text></navLabel><content src="one.xhtml"/></navPoint><navPoint id="two" playOrder="2"><navLabel><text>Chapter Two</text></navLabel><content src="two.xhtml"/></navPoint></navMap></ncx>',
            },
          ]
        : []),
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
    paths.set(title, path);
  }
  await triggerAndWaitForLibraryScan(ctx, library.libraryId);
  await triggerAndWaitForLibraryScan(ctx, secret.libraryId);
  for (const [title, path] of paths) {
    const file = await locateBookByAbsolutePath(ctx, path);
    files[title] = file;
    await ctx.db
      .insert(schema.bookMetadata)
      .values({ bookId: file.bookId, title, language: 'en', publisher: 'BookOrbit QA' })
      .onConflictDoUpdate({ target: schema.bookMetadata.bookId, set: { title, language: 'en', publisher: 'BookOrbit QA' } });
  }
  if (large) {
    await ctx.db.execute(sql`
      WITH seeded AS (
        INSERT INTO books (library_id, library_folder_id, folder_path)
        SELECT ${library.libraryId}, ${library.libraryFolderId}, 'qa-catalog-' || n FROM generate_series(1, ${50_000 - (titles.length - 1)}) n RETURNING id
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

export async function inspectNativeQA(ctx: ReaderStateIsolationE2EContext, libraryId: number, userId: number) {
  const [books] = await ctx.db.select({ total: count() }).from(schema.books).where(eq(schema.books.libraryId, libraryId));
  const [annotations] = await ctx.db.select({ total: count() }).from(schema.annotations).where(eq(schema.annotations.userId, userId));
  // The database may run in a different container from the fixture process.
  const result = await ctx.db.execute(sql`SELECT current_setting('data_directory') AS directory, pg_read_file('/proc/mounts', 0, 65536) AS mounts`);
  const { directory, mounts } = result.rows[0];
  if (typeof directory !== 'string' || typeof mounts !== 'string') throw new Error('Cannot inspect the QA database filesystem.');
  const mount = mounts
    .split('\n')
    .map((line) => line.split(/\s+/))
    .filter((parts) => directory === parts[1] || directory.startsWith(parts[1] === '/' ? '/' : parts[1] + '/'))
    .sort((a, b) => b[1].length - a[1].length)[0];
  if (!mount?.[2]) throw new Error('The QA database mount was not found.');
  return {
    books: books.total,
    annotations: annotations.total,
    databaseFilesystem: mount[2],
    storage: ['tmpfs', 'ramfs'].includes(mount[2]) ? 'tmpfs' : 'disk',
  };
}
