import { BadRequestException, ConflictException, ForbiddenException, Inject, Injectable, Logger, NotFoundException, Optional } from '@nestjs/common';
import { and, asc, eq, gt, inArray, or, sql } from 'drizzle-orm';
import type { NodePgDatabase } from 'drizzle-orm/node-postgres';
import {
  Permission,
  type NativeAnnotationDelta,
  type NativeAnnotationItem,
  type NativeAnnotationOperation,
  type NativeAnnotationOperationResult,
  type NativeAnnotationOperationsRequest,
  type NativeAnnotationOperationsResponse,
  type NativePdfPageSource,
} from '@bookorbit/types';
import { DB } from '../../db';
import * as schema from '../../db/schema';
import type { RequestUser } from '../../common/types/request-user';
import { sanitizeLogValue } from '../../common/utils/log-sanitize.utils';
import { BookService } from '../book/book.service';
import type { NativeAnnotationAckDto, NativeAnnotationDeltaQueryDto } from './dto/native-annotation.dto';

export const NATIVE_INK_PUBLISHER = 'NATIVE_INK_PUBLISHER';
interface InkPublisher {
  publish(input: {
    user: RequestUser;
    bookId: number;
    bookFileId: number;
    annotationId: number;
    version: number;
    deleted: boolean;
    drawing: NativeAnnotationItem['drawing'];
    page: number;
    sourceRevision: string | null;
    pageFingerprint?: string | null;
    operationId: string;
  }): Promise<{ sourceRevision: string; published: boolean }>;
  inspectPage(bookId: number, bookFileId: number, page: number, user: RequestUser, sourceRevision?: string): Promise<NativePdfPageSource>;
}
type Db = NodePgDatabase<typeof schema>;
type Tx = Parameters<Parameters<Db['transaction']>[0]>[0];

@Injectable()
export class NativeAnnotationService {
  private readonly logger = new Logger(NativeAnnotationService.name);
  constructor(
    @Inject(DB) private readonly db: Db,
    private readonly bookService: BookService,
    @Optional() @Inject(NATIVE_INK_PUBLISHER) private readonly publisher?: InkPublisher,
  ) {}

  async getItems(annotationIds: number[], userId: number): Promise<NativeAnnotationItem[]> {
    if (annotationIds.length > 100) throw new BadRequestException('At most 100 annotations may be read at once');
    return this.readItems(this.db, annotationIds, userId);
  }
  async getItem(annotationId: number, userId: number): Promise<NativeAnnotationItem | null> {
    return (await this.getItems([annotationId], userId))[0] ?? null;
  }
  async getSourceItems(bookId: number, annotationIds: number[], user: RequestUser): Promise<NativeAnnotationItem[]> {
    await this.bookService.verifyBookAccess(bookId, user);
    if (annotationIds.length > 100) throw new BadRequestException('At most 100 source ink items may be read at once');
    return this.readItems(this.db, annotationIds, user.id, bookId);
  }
  async sourceInkOperations(
    user: RequestUser,
    scope: { bookId: number; bookFileId: number },
    dto: NativeAnnotationOperationsRequest,
  ): Promise<NativeAnnotationOperationsResponse> {
    await this.bookService.verifyBookAccess(scope.bookId, user);
    const file = await this.bookService.verifyFileAccess(scope.bookFileId, user);
    if (file.bookId !== scope.bookId || file.format !== 'pdf') throw new BadRequestException('Source ink requires the selected PDF file');
    if (!user.isSuperuser && !user.permissions.includes(Permission.LibraryEditMetadata))
      throw new ForbiddenException('Source PDF ink requires metadata editing permission');
    if (
      dto.operations.some(
        (operation) =>
          operation.bookId !== scope.bookId || (operation.payload?.bookFileId != null && operation.payload.bookFileId !== scope.bookFileId),
      )
    )
      throw new BadRequestException('Source ink operations must target the selected book and file');
    return this.operations(user, dto, scope);
  }
  async recoverySnapshots(
    userId: number,
    operations: NativeAnnotationOperation[],
    sharedOperationIds: string[] = [],
  ): Promise<Map<string, NativeAnnotationItem>> {
    if (operations.length > 100) throw new BadRequestException('At most 100 recovery drafts may be read at once');
    return this.retainedSnapshots(this.db, userId, operations, new Set(sharedOperationIds));
  }
  async delta(user: RequestUser, query: NativeAnnotationDeltaQueryDto): Promise<NativeAnnotationDelta> {
    if (query.bookId) await this.bookService.verifyBookAccess(query.bookId, user);
    const cursor = Number(query.cursor ?? 0);
    const limit = Math.min(query.limit ?? 100, 100);
    const rows = await this.db
      .select({ id: schema.annotations.id, sequence: schema.annotations.changeSequence })
      .from(schema.annotations)
      .where(
        and(
          eq(schema.annotations.userId, user.id),
          gt(schema.annotations.changeSequence, cursor),
          ...(query.bookId ? [eq(schema.annotations.bookId, query.bookId)] : []),
        ),
      )
      .orderBy(asc(schema.annotations.changeSequence))
      .limit(limit + 1);
    const page = rows.slice(0, limit);
    return {
      items: await this.getItems(
        page.map((r) => r.id),
        user.id,
      ),
      nextCursor: String(page.at(-1)?.sequence ?? cursor),
      hasMore: rows.length > limit,
    };
  }
  async acknowledge(user: RequestUser, dto: NativeAnnotationAckDto): Promise<{ acknowledged: true }> {
    await this.bookService.verifyBookAccess(dto.bookId, user);
    await this.db
      .insert(schema.nativeAnnotationAcks)
      .values({ userId: user.id, deviceId: dto.deviceId, bookId: dto.bookId, cursor: Number(dto.cursor) })
      .onConflictDoUpdate({
        target: [schema.nativeAnnotationAcks.userId, schema.nativeAnnotationAcks.deviceId, schema.nativeAnnotationAcks.bookId],
        set: { cursor: sql`greatest(${schema.nativeAnnotationAcks.cursor}, ${Number(dto.cursor)})`, updatedAt: new Date() },
      });
    return { acknowledged: true };
  }

  async operations(
    user: RequestUser,
    dto: NativeAnnotationOperationsRequest,
    sourceScope?: { bookId: number; bookFileId: number },
  ): Promise<NativeAnnotationOperationsResponse> {
    const started = Date.now();
    this.logger.log(`[annotation.native_sync] [start] userId=${user.id} operations=${dto.operations.length} - annotation synchronization started`);
    try {
      const results: NativeAnnotationOperationResult[] = [];
      for (const operation of dto.operations) {
        await this.bookService.verifyBookAccess(operation.bookId, user);
        const pointCount = operation.payload?.drawing?.strokes.reduce((count, stroke) => count + stroke.points.length, 0) ?? 0;
        if (pointCount > 50000) throw new BadRequestException('A drawing may contain at most 50000 points');
        let sourceFailure: string | undefined;
        if (operation.payload?.bookFileId) {
          let file;
          try {
            file = await this.bookService.verifyFileAccess(operation.payload.bookFileId, user);
          } catch (error) {
            if (!(error instanceof NotFoundException)) throw error;
            sourceFailure = 'source_missing';
          }
          if (file) {
            if (file.bookId !== operation.bookId) throw new BadRequestException('Annotation file does not belong to this book');
            if (operation.payload.pdf && file.format !== 'pdf') throw new BadRequestException('PDF annotations require a PDF file');
          }
        }
        const previous = operation.annotationId
          ? sourceScope
            ? (await this.getSourceItems(sourceScope.bookId, [operation.annotationId], user))[0]
            : await this.getItem(operation.annotationId, user.id)
          : null;
        if (sourceScope && operation.annotationId && !previous)
          throw new ForbiddenException('Source operation does not target an accessible ink item');
        if (
          sourceScope &&
          ((previous && previous.jumpFileId !== sourceScope.bookFileId) ||
            (operation.payload?.kind !== undefined && operation.payload.kind !== 'pdf_ink'))
        )
          throw new BadRequestException('Source operation must target an ink item on the selected file');
        const pdf = operation.payload?.pdf ?? previous?.pdf;
        const fileId = operation.payload?.bookFileId ?? previous?.jumpFileId;
        const kind = operation.payload?.kind ?? previous?.kind;
        const privatePdfRepair = operation.action === 'repair' && operation.payload?.pdf != null && kind !== 'pdf_ink';
        if (
          sourceScope &&
          (kind !== 'pdf_ink' ||
            operation.payload?.cfi != null ||
            operation.payload?.note != null ||
            (operation.payload?.text != null && operation.payload.text !== ''))
        )
          throw new BadRequestException('Source ink cannot carry private passage content');
        if (kind === 'pdf_ink' && !fileId) sourceFailure = 'source_missing';
        if (privatePdfRepair && !fileId) sourceFailure = 'source_missing';
        if (!sourceFailure && (kind === 'pdf_ink' || privatePdfRepair) && pdf && fileId && this.publisher) {
          try {
            const fingerprint = privatePdfRepair
              ? operation.payload?.pageFingerprint
              : (operation.payload?.pageFingerprint ?? previous?.pageFingerprint);
            const revision = privatePdfRepair ? operation.payload?.sourceRevision : (operation.payload?.sourceRevision ?? previous?.sourceRevision);
            const source = await this.publisher.inspectPage(operation.bookId, fileId, pdf.page, user, revision ?? undefined);
            if (!revision) sourceFailure = 'source_revision_missing';
            else if (privatePdfRepair && !fingerprint) sourceFailure = 'source_page_identity_missing';
            else if (fingerprint && fingerprint !== source.pageFingerprint) sourceFailure = 'source_page_changed';
            else if (privatePdfRepair && source.sourceRevision !== revision && source.matchedSourceRevision !== revision)
              sourceFailure = 'source_revision_changed';
          } catch (error) {
            if (error instanceof NotFoundException) sourceFailure = 'source_missing';
            else if (error instanceof BadRequestException) sourceFailure = 'source_page_changed';
            else throw error;
          }
        }
        results.push(await this.apply(user, dto.deviceId, operation, sourceFailure, sourceScope));
      }
      await Promise.all(
        results.map(async (result) => {
          const item = result.annotation;
          if (result.status !== 'applied' || item?.kind !== 'pdf_ink' || !item.pdf || !item.jumpFileId || !this.publisher) return;
          try {
            const publication = await this.publisher.publish({
              user,
              bookId: item.bookId,
              bookFileId: item.jumpFileId,
              annotationId: item.id,
              version: item.version,
              deleted: item.deletedAt != null,
              drawing: item.drawing,
              page: item.pdf.page,
              sourceRevision: item.sourceRevision,
              pageFingerprint: item.pageFingerprint,
              operationId: result.operationId,
            });
            result.publication = { status: 'published', sourceRevision: publication.sourceRevision };
            {
              item.sourceRevision = publication.sourceRevision;
              await this.db.transaction(async (tx) => {
                await tx.execute(sql`select pg_advisory_xact_lock(7304, ${item.bookId})`);
                const [owner] = await tx
                  .select({ userId: schema.annotations.userId })
                  .from(schema.annotations)
                  .where(eq(schema.annotations.id, item.id))
                  .limit(1);
                for (const ownerId of [...new Set([user.id, owner?.userId ?? user.id])].sort((a, b) => a - b)) {
                  await tx.execute(sql`select pg_advisory_xact_lock(7303, ${ownerId})`);
                }
                await tx
                  .update(schema.annotations)
                  .set({ sourceRevision: publication.sourceRevision })
                  .where(
                    and(
                      eq(schema.annotations.id, item.id),
                      eq(schema.annotations.version, item.version),
                      sourceScope ? eq(schema.annotations.kind, 'pdf_ink') : eq(schema.annotations.userId, user.id),
                    ),
                  );
                await tx
                  .update(schema.nativeAnnotationOperations)
                  .set({ result })
                  .where(
                    and(eq(schema.nativeAnnotationOperations.userId, user.id), eq(schema.nativeAnnotationOperations.operationId, result.operationId)),
                  );
              });
            }
          } catch (error) {
            result.publication = { status: 'failed', message: error instanceof Error ? error.message.slice(0, 200) : 'Publication failed' };
            this.logger.warn(
              `[annotation.native_publish] [fail] annotationId=${item.id} userId=${user.id} durationMs=${Date.now() - started} errorClass=${error instanceof Error ? error.constructor.name : 'UnknownError'} error="${sanitizeLogValue(result.publication.message ?? '')}" - source ink publication failed`,
            );
          }
        }),
      );
      this.logger.log(
        `[annotation.native_sync] [end] userId=${user.id} durationMs=${Date.now() - started} applied=${results.filter((r) => r.status === 'applied').length} drafts=${results.filter((r) => r.draftId != null).length} - annotation synchronization completed`,
      );
      return { results };
    } catch (error) {
      this.logger.warn(
        `[annotation.native_sync] [fail] userId=${user.id} durationMs=${Date.now() - started} errorClass=${error instanceof Error ? error.constructor.name : 'UnknownError'} error="${sanitizeLogValue(error instanceof Error ? error.message : 'unknown error')}" - annotation synchronization failed`,
      );
      throw error;
    }
  }

  private async apply(
    user: RequestUser,
    deviceId: string,
    operation: NativeAnnotationOperation,
    sourceFailure?: string,
    sourceScope?: { bookId: number; bookFileId: number },
  ): Promise<NativeAnnotationOperationResult> {
    return this.db.transaction(async (tx) => {
      await tx.execute(sql`select pg_advisory_xact_lock(7304, ${operation.bookId})`);
      const identity = operation.annotationId
        ? eq(schema.annotations.id, operation.annotationId)
        : and(eq(schema.annotations.userId, user.id), eq(schema.annotations.clientId, operation.clientId));
      const [owner] = await tx.select({ userId: schema.annotations.userId }).from(schema.annotations).where(identity).limit(1);
      for (const ownerId of [...new Set([user.id, owner?.userId ?? user.id])].sort((a, b) => a - b)) {
        await tx.execute(sql`select pg_advisory_xact_lock(7303, ${ownerId})`);
      }
      const [previous] = await tx
        .select()
        .from(schema.nativeAnnotationOperations)
        .where(and(eq(schema.nativeAnnotationOperations.userId, user.id), eq(schema.nativeAnnotationOperations.operationId, operation.operationId)))
        .limit(1);
      if (previous) {
        if (JSON.stringify(previous.request) !== JSON.stringify(operation)) {
          const same = JSON.stringify(this.canonical(previous.request)) === JSON.stringify(this.canonical(operation));
          if (!same) throw new ConflictException('An operation identity cannot be reused with different content');
        }
        return previous.result;
      }
      const [current] = await tx.select().from(schema.annotations).where(identity).limit(1).for('update');
      if (current && current.userId !== user.id && (!sourceScope || current.kind !== 'pdf_ink'))
        throw new ForbiddenException('This annotation belongs to another reader');
      if (current && current.bookId !== operation.bookId) throw new BadRequestException('Annotation does not belong to this book');
      if (current?.clientId && current.clientId !== operation.clientId) throw new BadRequestException('Annotation identity does not match');
      const payload = operation.payload ?? {};
      const kind = payload.kind ?? current?.kind ?? 'highlight';
      if (kind === 'pdf_ink' || current?.kind === 'pdf_ink') {
        if (!user.isSuperuser && !user.permissions.includes(Permission.LibraryEditMetadata))
          throw new ForbiddenException('Source PDF ink requires metadata editing permission');
        if (current && (current.kind === 'pdf_ink') !== (kind === 'pdf_ink'))
          throw new BadRequestException('Private annotations cannot be converted into shared source ink');
        if (payload.cfi != null || payload.note != null || payload.chapterTitle != null || (payload.text != null && payload.text !== ''))
          throw new BadRequestException('Source ink cannot carry private passage content');
      }
      let reason: string | null = null;
      if (sourceFailure) reason = sourceFailure;
      if (!current && operation.action !== 'create') reason = 'annotation_missing';
      if (current && operation.action === 'create') reason = current.deletedAt ? 'annotation_deleted' : 'identity_exists';
      if (current?.deletedAt && operation.action !== 'restore') reason = 'annotation_deleted';
      if (current && current.version !== operation.baseVersion && !reason) reason = 'version_conflict';
      if (!current && operation.action === 'create' && operation.baseVersion !== 0) reason = 'version_conflict';
      if (reason) {
        const retained =
          current?.version === operation.baseVersion
            ? (await this.readItems(tx, [current.id], current.userId, sourceScope?.bookId))[0]
            : (await this.retainedSnapshots(tx, user.id, [operation], new Set(current?.kind === 'pdf_ink' ? [operation.operationId] : []))).get(
                operation.operationId,
              );
        const recoverySnapshot = retained ? this.intendedSnapshot(retained, operation) : undefined;
        const [draft] = await tx
          .insert(schema.nativeAnnotationDrafts)
          .values({
            userId: user.id,
            bookId: operation.bookId,
            annotationId: current?.id ?? null,
            operationId: operation.operationId,
            reason,
            payload: operation,
          })
          .returning({ id: schema.nativeAnnotationDrafts.id });
        const result: NativeAnnotationOperationResult = {
          operationId: operation.operationId,
          status: reason === 'version_conflict' || reason === 'identity_exists' ? 'conflict' : 'recovery',
          draftId: draft.id,
          ...(recoverySnapshot ? { recoverySnapshot } : { recoverySnapshotUnavailableReason: 'retained_base_unavailable' }),
          ...(current ? { annotation: (await this.readItems(tx, [current.id], current.userId))[0] } : {}),
        };
        await tx
          .insert(schema.nativeAnnotationOperations)
          .values({ userId: user.id, operationId: operation.operationId, deviceId, request: operation, result });
        return result;
      }
      if (operation.action === 'create') {
        if (!!payload.cfi === !!payload.pdf) throw new BadRequestException('Provide exactly one passage or PDF anchor');
        if (payload.pdf && !payload.bookFileId) throw new BadRequestException('PDF annotations require a book file');
        if ((kind === 'handwriting' || kind === 'pdf_ink') && !payload.drawing)
          throw new BadRequestException('Retained handwriting requires a drawing');
        if (kind === 'pdf_ink' && !payload.pdf) throw new BadRequestException('Source ink requires a PDF page anchor');
      }
      const patch = {
        ...(payload.text !== undefined ? { text: payload.text } : {}),
        ...(payload.color !== undefined ? { color: payload.color } : {}),
        ...(payload.style !== undefined ? { style: payload.style } : {}),
        ...(payload.note !== undefined ? { note: payload.note } : {}),
        ...(payload.chapterTitle !== undefined ? { chapterTitle: payload.chapterTitle } : {}),
        ...(payload.kind !== undefined ? { kind: payload.kind } : {}),
        ...(payload.drawing !== undefined ? { drawing: payload.drawing } : {}),
        ...(payload.sourceRevision !== undefined ? { sourceRevision: payload.sourceRevision } : {}),
        ...(payload.pageFingerprint !== undefined ? { pageFingerprint: payload.pageFingerprint } : {}),
      };
      const [row] = current
        ? await tx
            .update(schema.annotations)
            .set({
              ...patch,
              clientId: current.clientId ?? operation.clientId,
              version: current.version + 1,
              updatedAt: new Date(),
              ...(operation.action === 'delete' ? { deletedAt: new Date() } : operation.action === 'restore' ? { deletedAt: null } : {}),
            })
            .where(eq(schema.annotations.id, current.id))
            .returning()
        : await tx
            .insert(schema.annotations)
            .values({ userId: user.id, bookId: operation.bookId, clientId: operation.clientId, text: payload.text ?? '', ...patch })
            .returning();
      if (payload.cfi || payload.pdf) {
        const [previousPosition] = await tx
          .select({ bookFileId: schema.annotationPositions.bookFileId })
          .from(schema.annotationPositions)
          .where(and(eq(schema.annotationPositions.annotationId, row.id), eq(schema.annotationPositions.format, payload.pdf ? 'pdf' : 'cfi')))
          .limit(1);
        const position = {
          annotationId: row.id,
          userId: row.userId,
          bookFileId: payload.bookFileId ?? sourceScope?.bookFileId ?? previousPosition?.bookFileId ?? null,
          format: payload.pdf ? ('pdf' as const) : ('cfi' as const),
          pos0: payload.pdf ? JSON.stringify(payload.pdf) : payload.cfi!,
          status: operation.action === 'repair' ? ('repaired' as const) : ('exact' as const),
          extras: payload.pdf ? { pageno: payload.pdf.page + 1 } : null,
        };
        await tx
          .insert(schema.annotationPositions)
          .values(position)
          .onConflictDoUpdate({ target: [schema.annotationPositions.annotationId, schema.annotationPositions.format], set: position });
      }
      const result: NativeAnnotationOperationResult = {
        operationId: operation.operationId,
        status: 'applied',
        annotation: (await this.readItems(tx, [row.id], row.userId, sourceScope?.bookId))[0],
      };
      await tx
        .insert(schema.nativeAnnotationOperations)
        .values({ userId: user.id, operationId: operation.operationId, deviceId, request: operation, result });
      return result;
    });
  }

  private canonical(value: unknown): unknown {
    if (Array.isArray(value)) return value.map((entry) => this.canonical(entry));
    if (value && typeof value === 'object')
      return Object.fromEntries(
        Object.entries(value)
          .filter(([, entry]) => entry !== undefined)
          .sort(([a], [b]) => a.localeCompare(b))
          .map(([key, entry]) => [key, this.canonical(entry)]),
      );
    return value;
  }
  private async retainedSnapshots(
    db: Db | Tx,
    userId: number,
    operations: NativeAnnotationOperation[],
    sharedOperationIds: Set<string>,
  ): Promise<Map<string, NativeAnnotationItem>> {
    const eligible = operations.filter((operation) => operation.baseVersion > 0);
    if (!eligible.length) return new Map();
    const match = (operation: NativeAnnotationOperation) =>
      and(
        sql`${schema.nativeAnnotationOperations.result}->'annotation'->>'clientId' = ${operation.clientId}`,
        sql`(${schema.nativeAnnotationOperations.result}->'annotation'->>'version')::integer = ${operation.baseVersion}`,
        sql`(${schema.nativeAnnotationOperations.result}->'annotation'->>'bookId')::integer = ${operation.bookId}`,
        ...(operation.annotationId
          ? [sql`(${schema.nativeAnnotationOperations.result}->'annotation'->>'id')::integer = ${operation.annotationId}`]
          : []),
      );
    const shared = eligible.filter((operation) => sharedOperationIds.has(operation.operationId));
    const queries = [
      db
        .select({ annotation: sql<NativeAnnotationItem>`${schema.nativeAnnotationOperations.result}->'annotation'` })
        .from(schema.nativeAnnotationOperations)
        .where(
          and(
            eq(schema.nativeAnnotationOperations.userId, userId),
            sql`${schema.nativeAnnotationOperations.result}->>'status' = 'applied'`,
            or(...eligible.map(match)),
          ),
        )
        .limit(100),
    ];
    if (shared.length)
      queries.push(
        db
          .select({ annotation: sql<NativeAnnotationItem>`${schema.nativeAnnotationOperations.result}->'annotation'` })
          .from(schema.nativeAnnotationOperations)
          .where(
            and(
              sql`${schema.nativeAnnotationOperations.result}->>'status' = 'applied'`,
              sql`${schema.nativeAnnotationOperations.result}->'annotation'->>'kind' = 'pdf_ink'`,
              or(...shared.map(match)),
            ),
          )
          .limit(100),
      );
    const rows = (await Promise.all(queries)).flat();
    const result = new Map<string, NativeAnnotationItem>();
    for (const operation of eligible) {
      const retained = rows.find(
        ({ annotation }) =>
          annotation.clientId === operation.clientId &&
          annotation.version === operation.baseVersion &&
          annotation.bookId === operation.bookId &&
          (operation.annotationId == null || annotation.id === operation.annotationId),
      );
      if (retained) result.set(operation.operationId, this.intendedSnapshot(retained.annotation, operation));
    }
    return result;
  }
  private intendedSnapshot(base: NativeAnnotationItem, operation: NativeAnnotationOperation): NativeAnnotationItem {
    const payload = operation.payload ?? {};
    const snapshot = { ...base };
    for (const field of ['text', 'note', 'kind', 'drawing', 'color', 'style', 'chapterTitle', 'sourceRevision', 'pageFingerprint'] as const) {
      if (payload[field] !== undefined) Object.assign(snapshot, { [field]: payload[field] });
    }
    if (payload.bookFileId !== undefined) snapshot.jumpFileId = payload.bookFileId;
    if (payload.cfi !== undefined) {
      snapshot.cfi = payload.cfi;
      snapshot.pdf = null;
      snapshot.pageno = null;
    }
    if (payload.pdf !== undefined) {
      snapshot.pdf = payload.pdf;
      snapshot.cfi = null;
      snapshot.pageno = payload.pdf.page + 1;
    }
    return snapshot;
  }
  private async readItems(db: Db | Tx, ids: number[], userId: number, sourceBookId?: number): Promise<NativeAnnotationItem[]> {
    if (!ids.length) return [];
    const [rows, positions] = await Promise.all([
      db
        .select()
        .from(schema.annotations)
        .where(
          and(
            sourceBookId
              ? and(eq(schema.annotations.bookId, sourceBookId), eq(schema.annotations.kind, 'pdf_ink'))
              : eq(schema.annotations.userId, userId),
            inArray(schema.annotations.id, ids),
          ),
        ),
      db
        .select()
        .from(schema.annotationPositions)
        .where(and(...(sourceBookId ? [] : [eq(schema.annotationPositions.userId, userId)]), inArray(schema.annotationPositions.annotationId, ids))),
    ]);
    const mapped = new Map(
      rows.map((row) => {
        const cfi = positions.find((p) => p.annotationId === row.id && p.format === 'cfi');
        const pdf = positions.find((p) => p.annotationId === row.id && p.format === 'pdf');
        const pdfPosition = pdf?.pos0 ? (JSON.parse(pdf.pos0) as NativeAnnotationItem['pdf']) : null;
        const item: NativeAnnotationItem = {
          id: row.id,
          bookId: row.bookId,
          clientId: row.clientId,
          kind: row.kind,
          drawing: row.drawing,
          version: row.version,
          deletedAt: row.deletedAt?.toISOString() ?? null,
          sourceRevision: row.sourceRevision,
          pageFingerprint: row.pageFingerprint,
          cfi: cfi?.pos0 ?? null,
          jumpFileId: pdf?.bookFileId ?? cfi?.bookFileId ?? null,
          pageno: pdfPosition ? pdfPosition.page + 1 : null,
          text: row.text,
          note: row.note,
          color: row.color,
          style: row.style,
          chapterTitle: row.chapterTitle,
          origin: row.origin,
          positionStatus: cfi?.status ?? pdf?.status ?? null,
          chapterIndex: typeof cfi?.extras?.chapterIndex === 'number' ? cfi.extras.chapterIndex : null,
          highlightedAt: (row.sourceCreatedAt ?? row.createdAt).toISOString(),
          createdAt: row.createdAt.toISOString(),
          updatedAt: row.updatedAt.toISOString(),
          starredAt: row.starredAt?.toISOString() ?? null,
          pdf: pdfPosition,
        };
        if (sourceBookId) {
          item.text = '';
          item.note = null;
          item.cfi = null;
          item.chapterTitle = null;
          item.starredAt = null;
        }
        return [row.id, item] as const;
      }),
    );
    return ids.flatMap((id) => (mapped.get(id) ? [mapped.get(id)!] : []));
  }
}
