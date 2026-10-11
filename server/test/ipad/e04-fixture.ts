import { eq, inArray } from 'drizzle-orm';
import type { NodePgDatabase } from 'drizzle-orm/node-postgres';
import { Permission } from '@bookorbit/types';

import { APP_SETTING_KEYS } from '../../src/common/constants/app-settings.constants';
import * as schema from '../../src/db/schema';

export async function createE04Fixture(
  db: NodePgDatabase<typeof schema>,
  input: { libraryId: number; ownerId: number; passwordHash: string; smtpPort: number },
) {
  const accounts = [
    { username: 'ipad-e04-statistics', name: 'E04 Statistics Reader', settings: { timezone: 'UTC', dashboardConfig: { readingGoal: 12 } } },
    { username: 'ipad-e04-record', name: 'E04 Reading Record', settings: { timezone: 'UTC' } },
    { username: 'ipad-e04-insights-viewer', name: 'E04 Shared Insights Viewer', settings: { timezone: 'UTC' } },
  ];
  const created = await db
    .insert(schema.users)
    .values(accounts.map((account) => ({ ...account, passwordHash: input.passwordHash, isDefaultPassword: false, provisioningMethod: 'local' })))
    .returning({ id: schema.users.id, username: schema.users.username });
  const statistics = created.find((user) => user.username === 'ipad-e04-statistics')!;
  const record = created.find((user) => user.username === 'ipad-e04-record')!;
  const viewer = created.find((user) => user.username === 'ipad-e04-insights-viewer')!;
  await db
    .insert(schema.userLibraryAccess)
    .values(created.map(({ id }) => ({ userId: id, libraryId: input.libraryId, accessLevel: 'viewer' as const })));
  await db.insert(schema.userPermissions).values([
    { userId: statistics.id, permissionName: Permission.LibraryDownload },
    { userId: record.id, permissionName: Permission.LibraryDownload },
    { userId: record.id, permissionName: Permission.AnnotationManageOwn },
    { userId: record.id, permissionName: Permission.LibraryEditMetadata },
    { userId: viewer.id, permissionName: Permission.LibraryDownload },
    { userId: viewer.id, permissionName: Permission.ViewUserActivity },
  ]);
  const [emailReader] = await db.select({ id: schema.users.id }).from(schema.users).where(eq(schema.users.username, 'ipad-reader')).limit(1);
  if (!emailReader) throw new Error('The isolated E04 fixture requires its email ownership reader');
  await db.insert(schema.userPermissions).values({ userId: emailReader.id, permissionName: Permission.EmailSend });
  const [excludedTag] = await db.insert(schema.tags).values({ name: 'E04 restricted insight' }).returning({ id: schema.tags.id });
  await db.insert(schema.bookTags).values({ bookId: 2, tagId: excludedTag.id });
  await db.insert(schema.userContentFilterTags).values({ userId: viewer.id, tagId: excludedTag.id, filterType: 'exclude' });
  await db.update(schema.bookMetadata).set({ hardcoverId: '101', hardcoverEditionId: '501' }).where(eq(schema.bookMetadata.bookId, 1));
  const files = await db
    .select({ id: schema.bookFiles.id, format: schema.bookFiles.format })
    .from(schema.bookFiles)
    .where(eq(schema.bookFiles.bookId, 8))
    .limit(10);
  const readFile = files.find((file) => file.format === 'pdf');
  const listenFile = files.find((file) => file.format === 'm4a');
  if (!readFile || !listenFile) throw new Error('The isolated E04 fixture requires the mixed PDF and audio book');
  if (!Number.isInteger(input.smtpPort) || input.smtpPort < 1 || input.smtpPort > 65535)
    throw new Error('The isolated E04 fixture requires a receiver SMTP port');
  const [provider] = await db
    .insert(schema.emailProviders)
    .values({
      userId: input.ownerId,
      name: 'E04 controlled SMTP',
      host: '127.0.0.1',
      port: input.smtpPort,
      fromName: 'E04 receiver',
      fromAddress: 'sender@bookorbit.test',
      auth: false,
      ssl: false,
      startTls: false,
      tlsRejectUnauthorized: true,
      isDefault: true,
    })
    .returning({ id: schema.emailProviders.id });
  const [recipient] = await db
    .insert(schema.emailRecipients)
    .values({ userId: input.ownerId, name: 'E04 Kindle', email: 'reader@kindle.test', deviceType: 'kindle', preferredFormat: 'pdf', isDefault: true })
    .returning({ id: schema.emailRecipients.id });
  await db.insert(schema.emailPreferences).values({ userId: input.ownerId, defaultProviderId: provider.id, defaultRecipientId: recipient.id });
  const activityAccounts = await ensureE04ActivityAccounts(db, input);
  return {
    libraryId: input.libraryId,
    statistics: { username: statistics.username, userId: statistics.id, bookId: 8, readFileId: readFile.id, listenFileId: listenFile.id },
    readingRecord: { username: record.username, userId: record.id, bookId: 1, fileId: 1 },
    privacyViewerUserId: viewer.id,
    privacyViewerUsername: viewer.username,
    privacyExcludedTagId: excludedTag.id,
    privacyPermittedBookId: 1,
    privacyExcludedBookId: 2,
    email: { providerId: provider.id, recipientId: recipient.id, smtpPort: input.smtpPort, bookId: 1, fileId: 1 },
    hardcover: { bookId: 1, hardcoverBookId: 101, hardcoverEditionId: 501 },
    activity: { accounts: activityAccounts, pdfBookId: 1, pdfFileId: 1 },
  };
}

export async function ensureE04HardcoverReaderPermission(db: NodePgDatabase<typeof schema>) {
  const [reader] = await db.select({ id: schema.users.id }).from(schema.users).where(eq(schema.users.username, 'ipad-reader')).limit(1);
  if (!reader) throw new Error('The isolated E04 fixture requires its Hardcover reader');
  await db.insert(schema.userPermissions).values({ userId: reader.id, permissionName: Permission.HardcoverSync }).onConflictDoNothing();
}

export async function ensureE04ActivityAccounts(db: NodePgDatabase<typeof schema>, input: { libraryId: number; passwordHash: string }) {
  await ensureE04HardcoverReaderPermission(db);
  const usernames = [
    ...['listen', 'tts', 'recorded', 'offline', 'unknown'].map((kind) => `ipad-e04-activity-${kind}`),
    'ipad-e04-attempts',
    'ipad-e04-personal-recovery',
    'ipad-e04-recovery-other',
    'ipad-catalog',
  ];
  await db
    .insert(schema.users)
    .values(
      usernames.map((username) => ({
        username,
        name: username,
        passwordHash: input.passwordHash,
        isDefaultPassword: false,
        provisioningMethod: 'local',
        settings: { timezone: 'UTC' },
      })),
    )
    .onConflictDoNothing({ target: schema.users.username });
  const accounts = await db
    .select({ id: schema.users.id, username: schema.users.username })
    .from(schema.users)
    .where(inArray(schema.users.username, usernames))
    .limit(usernames.length);
  if (accounts.length !== usernames.length) throw new Error('The E04 activity accounts are incomplete');
  await db
    .insert(schema.userLibraryAccess)
    .values(accounts.map(({ id }) => ({ userId: id, libraryId: input.libraryId, accessLevel: 'viewer' as const })))
    .onConflictDoNothing();
  await db
    .insert(schema.userPermissions)
    .values(
      accounts.flatMap(({ id, username }) => {
        const permissions = [
          Permission.LibraryDownload,
          Permission.AnnotationManageOwn,
          ...(username === 'ipad-catalog' ? [Permission.OpdsAccess, Permission.KoreaderSync] : []),
        ];
        return permissions.map((permissionName) => ({ userId: id, permissionName }));
      }),
    )
    .onConflictDoNothing();
  await db
    .insert(schema.appSettings)
    .values({ key: APP_SETTING_KEYS.OPDS_ENABLED, value: 'true' })
    .onConflictDoUpdate({ target: schema.appSettings.key, set: { value: 'true' } });
  return accounts;
}

export async function initializeE04ReadingActivity(apiURL: string, fixture: Awaited<ReturnType<typeof createE04Fixture>>) {
  const response = await fetch(`${apiURL}/auth/login`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ username: fixture.statistics.username, password: 'IpadFixture123' }),
  });
  if (!response.ok) throw new Error(`E04 fixture login failed: ${response.status}`);
  const login = (await response.json()) as { accessToken: string };
  if (!login.accessToken) throw new Error('E04 fixture login did not return an access token');
  const headers = { 'Content-Type': 'application/json', Authorization: `Bearer ${login.accessToken}` };
  const day = new Date();
  day.setUTCDate(day.getUTCDate() - 1);
  const date = day.toISOString().slice(0, 10);
  const sessions = [
    {
      fileId: fixture.statistics.readFileId,
      sessionId: 'e04-statistics-read',
      startedAt: `${date}T10:00:00.000Z`,
      endedAt: `${date}T10:10:00.000Z`,
      durationSeconds: 600,
      progressDelta: 10,
      endProgress: 20,
      sessionType: 'read',
    },
    {
      fileId: fixture.statistics.listenFileId,
      sessionId: 'e04-statistics-listen',
      startedAt: `${date}T10:10:00.000Z`,
      endedAt: `${date}T10:15:00.000Z`,
      durationSeconds: 300,
      progressDelta: 5,
      endProgress: 25,
      sessionType: 'listen',
    },
  ];
  for (const { fileId, ...session } of sessions) {
    const saved = await fetch(`${apiURL}/books/files/${fileId}/sessions`, {
      method: 'POST',
      headers,
      body: JSON.stringify({ ...session, source: 'ios' }),
    });
    if (saved.status !== 204) throw new Error(`E04 fixture session save failed: ${saved.status}`);
  }
  const status = await fetch(`${apiURL}/books/${fixture.statistics.bookId}/status`, {
    method: 'PATCH',
    headers,
    body: JSON.stringify({ status: 'read', startedAt: date, finishedAt: date }),
  });
  if (!status.ok) throw new Error(`E04 fixture completion failed: ${status.status}`);
  return {
    day: date,
    totalSeconds: 900,
    readingSeconds: 600,
    listeningSeconds: 300,
    totalSessions: 2,
    completedBooks: 1,
    goalBooks: 12,
    source: 'ios',
  };
}
