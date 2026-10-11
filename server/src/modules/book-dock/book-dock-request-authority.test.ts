import { Test } from '@nestjs/testing';
import { Permission } from '@bookorbit/types';
import { BookDockFinalizeService } from './book-dock-finalize.service';
import { RequestVerificationService } from '../book-request/fulfillment/request-verification.service';

async function fixture(managed = true) {
  const user = { id: 7, isSuperuser: false, permissions: [Permission.BookRequestAccess] };
  const libraryService = { verifyUserAccessLevel: vi.fn().mockResolvedValue(undefined) };
  const publication = { publish: vi.fn(), cleanup: vi.fn() };
  const finalizations = { update: vi.fn(), find: vi.fn() };
  const uploadSessions = { recordDockFinalization: vi.fn() };
  const processor = { reconcileCoversAsync: vi.fn() };
  const auth = { findActingUser: vi.fn().mockResolvedValue(user) };
  const module = await Test.createTestingModule({
    providers: [
      {
        provide: BookDockFinalizeService,
        useFactory: () =>
          new BookDockFinalizeService(
            {} as never,
            {} as never,
            libraryService as never,
            {} as never,
            {} as never,
            {} as never,
            {} as never,
            {} as never,
            {} as never,
            processor as never,
            {} as never,
            {} as never,
            {} as never,
            {} as never,
            {} as never,
            undefined,
            undefined,
            uploadSessions as never,
            finalizations as never,
            publication as never,
            auth as never,
          ),
      },
    ],
  }).compile();
  const service = module.get(BookDockFinalizeService);
  const internal = service as any;
  vi.spyOn(internal, 'findLibraryOrFail').mockResolvedValue({ id: 2, fileWriteEnabled: false });
  vi.spyOn(internal, 'findFolderOrFail').mockResolvedValue({ id: 3, path: '/library' });
  vi.spyOn(internal, 'createUnitBookRecord').mockResolvedValue({ bookIds: [101], createdBookIds: [101], attachedFileIds: [] });
  vi.spyOn(internal, 'applyMetadata').mockResolvedValue(undefined);
  vi.spyOn(internal, 'cleanupBookDockRecord').mockResolvedValue(undefined);
  const journal = {
    fileId: 1,
    userId: 7,
    libraryId: 2,
    state: 'placing',
    bookIds: [],
    intent: {
      row: { id: 1, uploadedBy: 7, autoFinalizeSuppressed: managed, fileName: 'book.epub' },
      ...(managed ? { managedRequest: { requestId: 42, userId: 7 } } : {}),
      libraryId: 2,
      folderId: 3,
      root: '/library',
      destPath: '/library/book.epub',
      format: 'epub',
      placement: [],
      publication: [],
    },
  };
  return { service, internal, journal, publication, libraryService, uploadSessions, finalizations };
}

describe('managed request publication authority', () => {
  it('publishes an approved managed download for a request-only viewer and records its readable identity', async () => {
    const { internal, journal, publication, libraryService, uploadSessions, finalizations } = await fixture();
    delete (journal.intent as any).managedRequest;
    finalizations.find.mockResolvedValue(journal);
    expect(
      await internal.finalizeDurably({ fileId: 1, row: journal.intent.row, library: { id: 2 }, folder: { id: 3 } }, new Map(), 7, {
        requestId: 42,
        userId: 7,
      }),
    ).toMatchObject({ success: true, bookId: 101 });
    expect(finalizations.update).toHaveBeenCalledWith(
      1,
      expect.objectContaining({
        intent: expect.objectContaining({ managedRequest: { requestId: 42, userId: 7 } }),
      }),
    );
    expect(publication.publish).toHaveBeenCalledTimes(1);
    expect(libraryService.verifyUserAccessLevel).toHaveBeenCalledWith(7, 2, false, 'viewer');
    expect(uploadSessions.recordDockFinalization).toHaveBeenCalledWith(1, 7, 101);
  });

  it('files an approver review with requester ownership and managed authority', async () => {
    const { service, internal, journal, uploadSessions } = await fixture();
    const finalize = vi.spyOn(service, 'finalizeManagedFile').mockImplementation((fileId, destination, authority) => {
      expect(fileId).toBe(1);
      expect(destination).toEqual({ libraryId: 2, folderId: 3 });
      expect(authority).toEqual({ requestId: 42, userId: 7 });
      return internal.resumeFinalization(journal);
    });
    const requests = { updateIf: vi.fn().mockResolvedValue({ id: 42 }) };
    const downloads = { updateIf: vi.fn().mockResolvedValue({ id: 9 }) };
    const verifier = new RequestVerificationService(
      {} as never,
      {} as never,
      {} as never,
      service,
      downloads as never,
      requests as never,
      {} as never,
      { notifyBookAvailable: vi.fn() } as never,
      { emitChanged: vi.fn() } as never,
      {} as never,
    );
    vi.spyOn(verifier as any, 'loadHeld').mockResolvedValue({
      request: { id: 42, userId: 7, targetLibraryId: 2, targetFolderId: 3, title: 'Book' },
      download: { id: 9 },
      fileId: 1,
    });
    await verifier.fileHeldImport(42, { id: 99, isSuperuser: false, permissions: [Permission.ManageBookRequests] } as never);
    expect(finalize).toHaveBeenCalledTimes(1);
    expect(requests.updateIf).toHaveBeenCalledWith(42, ['importing', 'needs_review'], expect.objectContaining({ matchedBookId: 101 }));
    expect(uploadSessions.recordDockFinalization).toHaveBeenCalledWith(1, 7, 101);
  });

  it('rejects direct Dock publication for the same viewer without upload permissions', async () => {
    const { internal, journal, publication, finalizations } = await fixture(false);
    expect(await internal.resumeFinalization(journal)).toMatchObject({ success: false, message: expect.stringContaining('permission') });
    expect(publication.publish).not.toHaveBeenCalled();
    expect(finalizations.update).toHaveBeenCalledWith(1, expect.objectContaining({ state: 'failed' }));
  });
});
