import 'reflect-metadata';
import { copyFile, mkdtemp, readFile, rm, stat, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { NestFactory } from '@nestjs/core';
import { ValidationPipe } from '@nestjs/common';
import { FastifyAdapter, type NestFastifyApplication } from '@nestjs/platform-fastify';
import fastifyCookie from '@fastify/cookie';
import fastifyMultipart from '@fastify/multipart';
import { hash } from 'bcryptjs';
import { eq } from 'drizzle-orm';
import { PDFDocument, PDFHexString, PDFName, StandardFonts } from 'pdf-lib';
import { Permission } from '@bookorbit/types';

import { AppModule } from '../../src/app.module';
import { DB } from '../../src/db';
import * as schema from '../../src/db/schema';
import { GlobalExceptionFilter } from '../../src/common/filters/http-exception.filter';
import { BookCoverStore } from '../../src/modules/book-cover-store/book-cover-store.service';
import { sanitizeLogValue } from '../../src/common/utils/log-sanitize.utils';
import type { NodePgDatabase } from 'drizzle-orm/node-postgres';
import { FIXTURE_CLIENT_ID, FIXTURE_ISSUER, startOidcProvider } from './oidc-provider';

const started = Date.now();

async function main() {
  console.log(`[ipad.harness] [start] runId=${process.pid} books=50000 batchSize=500 - isolated harness starting`);
  const database = new URL(process.env.DATABASE_URL ?? '');
  if (!['localhost', '127.0.0.1'].includes(database.hostname) || !/^bookorbit_ipad_[0-9]+_e2e$/.test(database.pathname.slice(1))) {
    throw new Error('The iPad harness requires its own localhost bookorbit_ipad_<run>_e2e database');
  }
  const folder = await mkdtemp(join(tmpdir(), 'bookorbit-ipad-'));
  const progressOnly = process.env.IPAD_PROGRESS_ONLY === '1';
  const apiPort = progressOnly ? 16487 : 16482;
  process.env.APP_DATA_PATH = join(folder, 'data');
  process.env.COVER_SLOTS_BACKFILL_MODE = 'skip';
  const app = await NestFactory.create<NestFastifyApplication>(AppModule, new FastifyAdapter(), { logger: false, abortOnError: false });
  app.setGlobalPrefix('api/v1');
  app.useGlobalPipes(new ValidationPipe({ whitelist: true, forbidNonWhitelisted: true, transform: true }));
  app.useGlobalFilters(new GlobalExceptionFilter());
  await app.register(fastifyCookie as never);
  await app.register(fastifyMultipart as never, { limits: { fileSize: 20 * 1024 * 1024 } });
  const db = app.get<NodePgDatabase<typeof schema>>(DB);

  const passwordHash = await hash('IpadFixture123', 4);
  const [owner] = await db
    .insert(schema.users)
    .values({
      username: 'ipad-owner',
      name: 'iPad Owner',
      passwordHash,
      isSuperuser: true,
      isDefaultPassword: false,
      provisioningMethod: 'local',
    })
    .returning({ id: schema.users.id });
  await db.insert(schema.users).values({
    username: 'ipad-restricted',
    name: 'Restricted Reader',
    passwordHash,
    isSuperuser: false,
    isDefaultPassword: false,
    provisioningMethod: 'local',
  });
  const [reader, editor] = await db
    .insert(schema.users)
    .values([
      { username: 'ipad-reader', name: 'Library Viewer', passwordHash, isDefaultPassword: false, provisioningMethod: 'local' },
      { username: 'ipad-editor', name: 'Metadata Editor', passwordHash, isDefaultPassword: false, provisioningMethod: 'local' },
    ])
    .returning({ id: schema.users.id });
  await db.insert(schema.userPermissions).values({ userId: editor.id, permissionName: Permission.LibraryEditMetadata });
  const oidc = progressOnly ? undefined : await startOidcProvider();
  const [provider] = await db
    .insert(schema.oidcProviders)
    .values({
      slug: 'ipad-fixture',
      displayName: 'Test identity provider',
      enabled: true,
      issuerUri: FIXTURE_ISSUER,
      clientId: FIXTURE_CLIENT_ID,
    })
    .returning({ id: schema.oidcProviders.id });
  await db.insert(schema.oidcIdentities).values({
    userId: owner.id,
    providerId: provider.id,
    oidcSubject: 'ipad-owner-subject',
    oidcIssuer: FIXTURE_ISSUER,
  });
  const [library] = await db.insert(schema.libraries).values({ name: 'Large library', watch: false }).returning();
  await db.insert(schema.userLibraryAccess).values([
    { userId: reader.id, libraryId: library.id, accessLevel: 'viewer' },
    { userId: editor.id, libraryId: library.id, accessLevel: 'editor' },
  ]);
  const [libraryFolder] = await db.insert(schema.libraryFolders).values({ libraryId: library.id, path: folder }).returning();
  for (let offset = 0; offset < 50_000; offset += 500) {
    const batch = Array.from({ length: 500 }, (_, index) => ({
      libraryId: library.id,
      libraryFolderId: libraryFolder.id,
      folderPath: join(folder, `book-${offset + index}`),
      addedAt: new Date('2026-01-01T00:00:00Z'),
    }));
    const created = await db.insert(schema.books).values(batch).returning({ id: schema.books.id });
    await db.insert(schema.bookMetadata).values(
      created.map(({ id }, index) => ({
        bookId: id,
        title: offset === 0 && index === 0 ? 'Orbit fixture' : `Library book ${String(offset + index).padStart(5, '0')}`,
        language: index % 2 ? 'eng' : 'urd',
      })),
    );
  }
  const document = await PDFDocument.create();
  const font = await document.embedFont(StandardFonts.Helvetica);
  for (let index = 0; index < 3; index++) {
    document.addPage([600, 800]).drawText(`Orbit fixture: passage ${index + 1}`, { x: 50, y: 700, font, size: 20 });
  }
  const context = document.context;
  const outlines = context.obj({ Type: 'Outlines' });
  const outlinesRef = context.register(outlines);
  const chapters = context.obj({ Title: PDFHexString.fromText('Orbit chapters'), Parent: outlinesRef, Count: 3 });
  const chaptersRef = context.register(chapters);
  const chapterRefs = document.getPages().map(() => context.nextRef());
  const chapterTitles = ['First passage', 'Second passage', 'Third passage'];
  for (const [index, page] of document.getPages().entries()) {
    context.assign(
      chapterRefs[index],
      context.obj({
        Title: PDFHexString.fromText(chapterTitles[index]),
        Parent: chaptersRef,
        Dest: [page.ref, 'Fit'],
        Prev: chapterRefs[index - 1],
        Next: chapterRefs[index + 1],
      }),
    );
  }
  chapters.set(PDFName.of('First'), chapterRefs[0]);
  chapters.set(PDFName.of('Last'), chapterRefs[2]);
  outlines.set(PDFName.of('First'), chaptersRef);
  outlines.set(PDFName.of('Last'), chaptersRef);
  outlines.set(PDFName.of('Count'), context.obj(4));
  document.catalog.set(PDFName.of('Outlines'), outlinesRef);
  const pdf = await document.save();
  const pdfPath = join(folder, 'orbit.pdf');
  await writeFile(pdfPath, pdf);
  const [file] = await db
    .insert(schema.bookFiles)
    .values({
      bookId: 1,
      libraryFolderId: libraryFolder.id,
      absolutePath: pdfPath,
      ino: 1n,
      format: 'pdf',
      role: 'content',
      sizeBytes: pdf.length,
    })
    .returning({ id: schema.bookFiles.id });
  await db.update(schema.books).set({ primaryFileId: file.id }).where(eq(schema.books.id, 1));
  if (process.env.IPAD_READER_PROOF_EPUB) {
    const epubPath = join(folder, 'reader-proof.epub');
    await copyFile(process.env.IPAD_READER_PROOF_EPUB, epubPath);
    const [epub] = await db
      .insert(schema.bookFiles)
      .values({
        bookId: 2,
        libraryFolderId: libraryFolder.id,
        absolutePath: epubPath,
        ino: 2n,
        format: 'epub',
        role: 'content',
        sizeBytes: (await stat(epubPath)).size,
      })
      .returning({ id: schema.bookFiles.id });
    await db.update(schema.books).set({ primaryFileId: epub.id }).where(eq(schema.books.id, 2));
    await db.update(schema.bookMetadata).set({ title: 'Native renderer proof' }).where(eq(schema.bookMetadata.bookId, 2));
  }
  const coverFixtureFolder = process.env.IPAD_COVER_FIXTURE_DIR;
  if (!coverFixtureFolder) throw new Error('The iPad harness requires its generated cover fixture folder');
  for (const bookId of [6, 8]) {
    const mixedPDF = join(folder, `cover-book-${bookId}.pdf`);
    const mixedAudio = join(folder, `cover-audio-${bookId}.m4a`);
    await copyFile(pdfPath, mixedPDF);
    await copyFile(join(coverFixtureFolder, 'cover-audio.m4a'), mixedAudio);
    const mixedFiles = await db
      .insert(schema.bookFiles)
      .values([
        {
          bookId,
          libraryFolderId: libraryFolder.id,
          absolutePath: mixedPDF,
          ino: BigInt(bookId),
          format: 'pdf',
          role: 'content',
          sizeBytes: pdf.length,
        },
        {
          bookId,
          libraryFolderId: libraryFolder.id,
          absolutePath: mixedAudio,
          ino: BigInt(bookId + 1),
          format: 'm4a',
          role: 'content',
          sizeBytes: (await stat(mixedAudio)).size,
        },
      ])
      .returning({ id: schema.bookFiles.id });
    await db.update(schema.books).set({ primaryFileId: mixedFiles[0].id }).where(eq(schema.books.id, bookId));
  }
  await app.listen(apiPort, '127.0.0.1');
  const coverStore = app.get(BookCoverStore);
  for (const bookId of [6, 8]) {
    for (const medium of ['ebook', 'audio'] as const) {
      await coverStore.saveExtracted(bookId, medium, await readFile(join(coverFixtureFolder, `${medium}-extracted.png`)), {
        origin: 'embedded',
        overwrite: true,
      });
    }
  }
  console.log(`[ipad.harness] [end] runId=${process.pid} durationMs=${Date.now() - started} books=50000 port=${apiPort} - localhost server ready`);
  const close = async () => {
    await app.close();
    if (oidc) await new Promise<void>((resolve, reject) => oidc.close((error) => (error ? reject(error) : resolve())));
    await rm(folder, { recursive: true, force: true });
    process.exit(0);
  };
  process.once('SIGTERM', () => void close());
  process.once('SIGINT', () => void close());
}

void main().catch((error: unknown) => {
  const errorClass = error instanceof Error ? error.name : 'UnknownError';
  const message = error instanceof Error ? error.message : 'Unknown error';
  console.error(
    `[ipad.harness] [fail] runId=${process.pid} durationMs=${Date.now() - started} errorClass=${errorClass} error="${sanitizeLogValue(message)}" - harness failed`,
  );
  process.exit(1);
});
