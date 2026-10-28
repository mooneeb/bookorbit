import { Test } from '@nestjs/testing';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createZipArchiveFixture } from '../../../../test/e2e/reader-state-isolation/reader-state-isolation-fixture-builder';
import { EpubService } from './epub.service';
import { EpubSessionService } from './epub-session.service';
import type { RequestUser } from '../../../common/types/request-user';

it('serves verified immutable bytes only to the opening owner and rechecks library access', async () => {
  const root = await mkdtemp(join(tmpdir(), 'epub-session-test-'));
  const path = await createZipArchiveFixture(root, 'book.epub', [
    { path: 'META-INF/container.xml', content: 'container' },
    { path: 'chapter.xhtml', content: '<p>Readable original words</p>' },
  ]);
  const resolveOriginalPath = vi.fn().mockResolvedValue(path);
  const module = await Test.createTestingModule({
    providers: [EpubSessionService, { provide: EpubService, useValue: { resolveOriginalPath } }],
  }).compile();
  const service = module.get(EpubSessionService);
  const owner = { id: 11, isSuperuser: false } as RequestUser;
  try {
    const session = await service.open(1, 2, owner);
    expect(session.sourceSha256).toMatch(/^[0-9a-f]{64}$/);
    const index = session.members.findIndex((member) => member.path === 'chapter.xhtml');
    const resource = await service.resource(session.id, index, owner);
    let text = '';
    for await (const chunk of resource.stream) text += chunk.toString();
    expect(text).toBe('<p>Readable original words</p>');
    expect(session.members[index].sha256).toBe('83708e51091dc327f26b675080795a586a20a6eaecc9d2e4885fa6e30af9dfc2');
    await expect(service.resource(session.id, index, { ...owner, id: 12 })).rejects.toThrow();
    resolveOriginalPath.mockRejectedValueOnce(new Error('denied'));
    await expect(service.resource(session.id, index, owner)).rejects.toThrow('denied');
  } finally {
    await service.onModuleDestroy();
    await rm(root, { recursive: true, force: true });
  }
});

it('refuses ambiguous paths and oversized chapters without retaining a broken lease', async () => {
  const root = await mkdtemp(join(tmpdir(), 'epub-session-limits-'));
  const resolveOriginalPath = vi.fn();
  const module = await Test.createTestingModule({
    providers: [EpubSessionService, { provide: EpubService, useValue: { resolveOriginalPath } }],
  }).compile();
  const service = module.get(EpubSessionService);
  const owner = { id: 13, isSuperuser: false } as RequestUser;
  try {
    const ambiguous = await createZipArchiveFixture(root, 'ambiguous.epub', [
      { path: 'chapter.xhtml', content: 'first' },
      { path: 'chapter.xhtml', content: 'second' },
    ]);
    resolveOriginalPath.mockResolvedValue(ambiguous);
    await expect(service.open(1, 2, owner)).rejects.toThrow('Ambiguous or invalid archive member');
    const oversized = await createZipArchiveFixture(root, 'oversized.epub', [{ path: 'chapter.xhtml', content: Buffer.alloc(4 * 1024 * 1024 + 1) }]);
    resolveOriginalPath.mockResolvedValue(oversized);
    await expect(service.open(1, 2, owner)).rejects.toThrow('EPUB expanded resource limit exceeded');
    const valid = await createZipArchiveFixture(root, 'valid.epub', [{ path: 'chapter.xhtml', content: '<p>Read me</p>' }]);
    resolveOriginalPath.mockResolvedValue(valid);
    const publication = await service.open(1, 2, owner);
    expect(publication.members).toHaveLength(1);
    const reopened = await service.open(1, 2, owner);
    await expect(service.resource(publication.id, 0, owner)).rejects.toThrow('Reader lease expired');
    await service.close(reopened.id, owner);
    await expect(service.resource(publication.id, 0, owner)).rejects.toThrow('Reader lease expired');
  } finally {
    await service.onModuleDestroy();
    await rm(root, { recursive: true, force: true });
  }
});

it('renews active reading, expires idle snapshots and lets independent readers and reopened sessions continue', async () => {
  const root = await mkdtemp(join(tmpdir(), 'epub-session-lifecycle-'));
  const path = await createZipArchiveFixture(root, 'book.epub', [{ path: 'chapter.xhtml', content: '<p>Still reading</p>' }]);
  const resolveOriginalPath = vi.fn().mockResolvedValue(path);
  const module = await Test.createTestingModule({
    providers: [EpubSessionService, { provide: EpubService, useValue: { resolveOriginalPath } }],
  }).compile();
  const service = module.get(EpubSessionService);
  const owner = { id: 21, sessionId: 101, isSuperuser: false } as RequestUser;
  const start = Date.now();
  const clock = vi.spyOn(Date, 'now').mockReturnValue(start);
  try {
    const first = await service.open(1, 2, owner);
    clock.mockReturnValue(start + 29 * 60_000);
    await service.heartbeat(first.id, owner);
    clock.mockReturnValue(start + 31 * 60_000);
    const ongoing = await service.resource(first.id, 0, owner);
    ongoing.stream.destroy();
    const otherDevice = { ...owner, sessionId: 102 };
    const second = await service.open(1, 2, otherDevice);
    const reopened = await service.open(1, 2, owner);
    await expect(service.resource(first.id, 0, owner)).rejects.toThrow('Reader lease expired');
    (await service.resource(second.id, 0, otherDevice)).stream.destroy();
    (await service.resource(reopened.id, 0, owner)).stream.destroy();
    for (let index = 0; index < 5; index++) {
      const independent = { ...owner, id: 30 + index, sessionId: 200 + index };
      const opened = await service.open(1, 2, independent);
      (await service.resource(opened.id, 0, independent)).stream.destroy();
    }
    clock.mockReturnValue(start + 62 * 60_000);
    await expect(service.resource(reopened.id, 0, owner)).rejects.toThrow('Reader lease expired');
    const afterIdle = await service.open(1, 2, owner);
    expect(afterIdle.id).not.toBe(reopened.id);
    await service.close(afterIdle.id, owner);
  } finally {
    clock.mockRestore();
    await service.onModuleDestroy();
    await rm(root, { recursive: true, force: true });
  }
});

it('rejects overlapping preparation for one owner while allowing a retry after completion', async () => {
  const root = await mkdtemp(join(tmpdir(), 'epub-session-busy-'));
  const path = await createZipArchiveFixture(root, 'book.epub', [{ path: 'chapter.xhtml', content: '<p>Readable</p>' }]);
  let release!: (path: string) => void;
  let entered!: () => void;
  const waiting = new Promise<void>((resolve) => {
    entered = resolve;
  });
  const resolveOriginalPath = vi
    .fn()
    .mockImplementationOnce(() => {
      entered();
      return new Promise<string>((resolve) => {
        release = resolve;
      });
    })
    .mockResolvedValue(path);
  const module = await Test.createTestingModule({
    providers: [EpubSessionService, { provide: EpubService, useValue: { resolveOriginalPath } }],
  }).compile();
  const service = module.get(EpubSessionService);
  const owner = { id: 40, sessionId: 301, isSuperuser: false } as RequestUser;
  try {
    const preparing = service.open(1, 2, owner);
    await waiting;
    await expect(service.open(1, 2, owner)).rejects.toThrow('preparation is busy');
    release(path);
    await preparing;
    await expect(service.open(1, 2, owner)).resolves.toMatchObject({ bookId: 1, fileId: 2 });
  } finally {
    release(path);
    await service.onModuleDestroy();
    await rm(root, { recursive: true, force: true });
  }
});
