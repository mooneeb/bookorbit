import { copyFile, mkdir, stat, writeFile } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import { eq, inArray } from 'drizzle-orm';
import { hash } from 'bcryptjs';
import { Permission } from '@bookorbit/types';
import type { NodePgDatabase } from 'drizzle-orm/node-postgres';
import * as schema from '../../src/db/schema';
import { APP_SETTING_KEYS } from '../../src/common/constants/app-settings.constants';
import { computeFileHash } from '../../src/common/utils/file-hash.utils';

export async function createE03Fixture(db: NodePgDatabase<typeof schema>, folder: string) {
  const passwordHash = await hash(process.env.IPAD_FIXTURE_PASSWORD ?? 'IpadFixture123', 4);
  const created = await db
    .insert(schema.users)
    .values([
      { username: 'ipad-settings-admin', name: 'Settings Operator', passwordHash, isDefaultPassword: false },
      { username: 'ipad-request-moderator', name: 'Request Moderator', passwordHash, isDefaultPassword: false },
      { username: 'ipad-maintainer', name: 'Library Maintainer', passwordHash, isDefaultPassword: false },
    ])
    .returning({ id: schema.users.id, username: schema.users.username });
  const users = await db
    .select({ id: schema.users.id, username: schema.users.username })
    .from(schema.users)
    .where(inArray(schema.users.username, ['ipad-owner', 'ipad-editor', 'ipad-reader', ...created.map((user) => user.username)]));
  const grants: Record<string, Permission[]> = {
    'ipad-editor': [Permission.LibraryUpload, Permission.BookDockAccess, Permission.LibraryDownload],
    'ipad-reader': [Permission.BookRequestAccess, Permission.LibraryDownload],
    'ipad-settings-admin': [Permission.ManageAppSettings, Permission.BookRequestAccess],
    'ipad-request-moderator': [Permission.ManageBookRequests, Permission.BookRequestAccess],
    'ipad-maintainer': [Permission.ManageLibraries, Permission.LibraryDeleteBooks, Permission.LibraryEditMetadata, Permission.LibraryDownload],
  };
  await db
    .insert(schema.userPermissions)
    .values(users.flatMap((user) => (grants[user.username] ?? []).map((permissionName) => ({ userId: user.id, permissionName }))))
    .onConflictDoNothing();
  await db
    .insert(schema.appSettings)
    .values([
      { key: APP_SETTING_KEYS.BOOK_DOCK_AUTO_FETCH_METADATA, value: 'false' },
      { key: APP_SETTING_KEYS.BOOK_DOCK_AUTO_FINALIZE_ENABLED, value: 'false' },
    ])
    .onConflictDoUpdate({ target: schema.appSettings.key, set: { value: 'false' } });
  const importRoot = join(folder, 'e03-imports');
  const scanRoot = join(folder, 'e03-scan');
  const migrationRoot = join(folder, 'e03-migrations');
  const downloadRoot = join(folder, 'e03-downloads');
  for (const directory of [importRoot, scanRoot, migrationRoot, downloadRoot]) await mkdir(directory, { recursive: true });
  const libraries = await db
    .insert(schema.libraries)
    .values([
      { name: 'Fixture library', watch: false, organizationMode: 'book_per_folder', fileWriteEnabled: false, fileRenameEnabled: true },
      { name: 'E03 scan fixture', watch: false, organizationMode: 'book_per_file' },
    ])
    .returning();
  const folders = await db
    .insert(schema.libraryFolders)
    .values([
      { libraryId: libraries[0].id, path: importRoot },
      { libraryId: libraries[1].id, path: scanRoot },
    ])
    .returning();
  await db
    .insert(schema.userLibraryAccess)
    .values(
      users
        .filter((user) => user.username !== 'ipad-owner')
        .flatMap((user) =>
          libraries.map((library) => ({
            userId: user.id,
            libraryId: library.id,
            accessLevel: user.username === 'ipad-editor' || user.username === 'ipad-maintainer' ? ('editor' as const) : ('viewer' as const),
          })),
        ),
    )
    .onConflictDoNothing();
  const source = join(folder, 'orbit.pdf');
  const uploadFile = join(folder, 'E03 upload.pdf');
  const scanFile = join(scanRoot, 'e03-scan.pdf');
  await copyFile(source, uploadFile);
  await copyFile(source, scanFile);
  async function missingResource(kind: 'native' | 'http') {
    const label = kind === 'native' ? 'Missing resource' : 'HTTP missing resource';
    const repairRoot = join(importRoot, `Repaired ${kind} resource`);
    await mkdir(repairRoot, { recursive: true });
    const replacementPath = join(repairRoot, `${label}.pdf`);
    await copyFile(source, replacementPath);
    const [missing] = await db
      .insert(schema.books)
      .values({ libraryId: libraries[0].id, libraryFolderId: folders[0].id, folderPath: join(importRoot, label), status: 'missing' })
      .returning({ id: schema.books.id, folderPath: schema.books.folderPath });
    await db.insert(schema.bookMetadata).values({ bookId: missing.id, title: `E03 ${label.toLowerCase()}` });
    const [missingFile] = await db
      .insert(schema.bookFiles)
      .values({
        bookId: missing.id,
        libraryFolderId: folders[0].id,
        absolutePath: join(missing.folderPath, `${label}.pdf`),
        ino: kind === 'native' ? 99_001n : 99_002n,
        format: 'pdf',
        role: 'content',
        sizeBytes: (await stat(replacementPath)).size,
        fileHash: await computeFileHash(replacementPath),
      })
      .returning({ id: schema.bookFiles.id });
    await db.update(schema.books).set({ primaryFileId: missingFile.id }).where(eq(schema.books.id, missing.id));
    return { libraryId: libraries[0].id, missingBookId: missing.id, missingFileId: missingFile.id, replacementPath };
  }
  const maintenance = await missingResource('native');
  const maintenanceHttp = await missingResource('http');
  const manifest = {
    version: 1,
    contentRoot: folder,
    libraryId: libraries[0].id,
    libraryFolderId: folders[0].id,
    libraryPath: importRoot,
    scanLibraryId: libraries[1].id,
    scanLibraryFolderId: folders[1].id,
    scanPath: scanRoot,
    scanFile,
    uploadFile,
    migrationRoot,
    downloadRoot,
    users: Object.fromEntries(users.map((user) => [user.username, user.id])),
    maintenance,
    maintenanceHttp,
  };
  const manifestPath = process.env.IPAD_E03_FIXTURE_FILE;
  if (!manifestPath) throw new Error('E03 fixtures require a manifest destination');
  await mkdir(dirname(manifestPath), { recursive: true });
  await writeFile(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`);
  return manifest;
}
