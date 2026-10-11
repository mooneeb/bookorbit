import {
  BadRequestException,
  ConflictException,
  ForbiddenException,
  Injectable,
  Logger,
  NotFoundException,
  OnApplicationBootstrap,
  OnModuleDestroy,
} from '@nestjs/common';
import type { BookDockFinalizeJob, BookDockFinalizeJobRequest } from '@bookorbit/types';
import { Permission } from '@bookorbit/types';
import type { RequestUser } from '../../common/types/request-user';
import { sanitizeLogValue } from '../../common/utils/log-sanitize.utils';
import { AuthService } from '../auth/auth.service';
import { BookDockFinalizationRepository } from './book-dock-finalization.repository';
import { BookDockRepository } from './book-dock.repository';
import { BookDockFinalizeService } from './book-dock-finalize.service';
import { BookDockWorkQueue } from './book-dock-work-queue';

@Injectable()
export class BookDockFinalizeJobsService implements OnApplicationBootstrap, OnModuleDestroy {
  private readonly logger = new Logger(BookDockFinalizeJobsService.name);
  private readonly queue: BookDockWorkQueue;
  private timer?: ReturnType<typeof setInterval>;
  private stopped = false;
  constructor(
    private readonly repo: BookDockFinalizationRepository,
    private readonly dock: BookDockRepository,
    private readonly finalizeService: BookDockFinalizeService,
    private readonly auth: AuthService,
  ) {
    this.queue = new BookDockWorkQueue(
      1,
      (id) => this.run(id),
      (id, error) => this.logFailure(id, error),
    );
  }

  onApplicationBootstrap(): void {
    void this.finalizeService
      .recoverFinalizations()
      .then(() => this.pump())
      .catch((error) => this.logFailure(0, error));
    this.timer = setInterval(() => void this.pump().catch((error) => this.logFailure(0, error)), 5000);
    this.timer.unref();
  }

  onModuleDestroy(): void {
    this.stopped = true;
    if (this.timer) clearInterval(this.timer);
    this.queue.stop();
  }

  async create(user: RequestUser, request: BookDockFinalizeJobRequest): Promise<BookDockFinalizeJob> {
    this.assertPermissions(user);
    if (!request.selectAll && !request.fileIds?.length) throw new BadRequestException('Select at least one Book Dock file');
    const job = await this.repo.createJob(user.id, request);
    if (canonical(job.request) !== canonical(request)) throw new ConflictException('Idempotency key already belongs to a different import request');
    this.queue.enqueue(job.id);
    return this.status(user, job.id);
  }

  async status(user: RequestUser, id: number): Promise<BookDockFinalizeJob> {
    this.assertPermissions(user);
    const job = await this.repo.findJob(id, user.id);
    if (!job) throw new NotFoundException('Import job not found');
    const rows = await this.repo.results(id);
    return {
      id: job.id,
      state: job.state as BookDockFinalizeJob['state'],
      total: job.total,
      processed: job.succeeded + job.failed,
      succeeded: job.succeeded,
      failed: job.failed,
      error: job.error,
      createdAt: job.createdAt.toISOString(),
      updatedAt: job.updatedAt.toISOString(),
      results: rows.flatMap((row) => (row.result ? [row.result] : [])),
      resultsTruncated: job.succeeded + job.failed > rows.length,
    };
  }

  async retry(user: RequestUser, id: number): Promise<BookDockFinalizeJob> {
    await this.status(user, id);
    await this.repo.locked(4105, id, async () => {
      const job = await this.repo.findJob(id, user.id);
      if (job?.state === 'failed') await this.repo.retryJob(id);
    });
    this.queue.enqueue(id);
    return this.status(user, id);
  }

  private async pump(): Promise<void> {
    if (this.stopped) return;
    for (const job of await this.repo.unfinishedJobs()) this.queue.enqueue(job.id);
  }

  private async run(id: number): Promise<void> {
    await this.repo.locked(4105, id, async () => {
      const jobs = await this.repo.unfinishedJobs();
      const job = jobs.find((row) => row.id === id);
      if (!job) return;
      const started = Date.now();
      this.logger.log(`[book_dock.finalize_job] [start] jobId=${id} userId=${job.userId} - import job started`);
      try {
        let user = await this.auth.findActingUser(job.userId);
        if (!user) throw new ForbiddenException('Import owner is no longer active');
        this.assertPermissions(user);
        if (job.state === 'queued') {
          if (job.request.selectAll) {
            await this.dock.snapshotFinalizeSelection(id, job.createdAt, {
              ...job.request,
              userId: user.id,
              canManageAll: this.canManageAll(user),
              limit: 100,
            });
          } else await this.repo.addItems(id, [...new Set(job.request.fileIds ?? [])]);
          await this.repo.updateJob(id, { total: await this.repo.countItems(id), state: 'running', error: null });
        }
        while (!this.stopped) {
          const items = await this.repo.nextItems(id);
          if (!items.length) break;
          for (const item of items) {
            if (this.stopped) return;
            user = await this.auth.findActingUser(job.userId);
            if (!user) throw new ForbiddenException('Import owner is no longer active');
            this.assertPermissions(user);
            const result = await this.finalizeService.finalizeQueuedFile(user, item.fileId, job.request);
            await this.repo.recordItem(id, item.id, result);
          }
        }
        const current = await this.repo.findJob(id, job.userId);
        await this.repo.updateJob(id, { state: current?.failed ? 'failed' : 'completed' });
        this.logger.log(
          `[book_dock.finalize_job] [end] jobId=${id} userId=${job.userId} durationMs=${Date.now() - started} succeeded=${current?.succeeded ?? 0} failed=${current?.failed ?? 0} - import job settled`,
        );
      } catch (error) {
        await this.repo.updateJob(id, {
          state: 'failed',
          error: error instanceof ForbiddenException ? error.message : 'Import interrupted. Retry to continue',
        });
        this.logFailure(id, error, started);
      }
    });
  }

  private assertPermissions(user: RequestUser): void {
    if (
      !user.active ||
      (!user.isSuperuser && (!user.permissions.includes(Permission.BookDockAccess) || !user.permissions.includes(Permission.LibraryUpload)))
    )
      throw new ForbiddenException('Book Dock access and library upload permissions are required');
  }
  private canManageAll(user: RequestUser): boolean {
    return user.isSuperuser || user.permissions.includes(Permission.ManageBookDock);
  }
  private logFailure(id: number, error: unknown, started = Date.now()): void {
    this.logger.warn(
      `[book_dock.finalize_job] [fail] jobId=${id} durationMs=${Date.now() - started} errorClass=${error instanceof Error ? error.name : 'Unknown'} error="${sanitizeLogValue(error instanceof Error ? error.message : 'Import failed')}" - import job failed`,
    );
  }
}

function canonical(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(canonical).join(',')}]`;
  if (value && typeof value === 'object')
    return `{${Object.entries(value)
      .filter(([, entry]) => entry !== undefined)
      .sort(([left], [right]) => left.localeCompare(right))
      .map(([key, entry]) => `${JSON.stringify(key)}:${canonical(entry)}`)
      .join(',')}}`;
  return JSON.stringify(value);
}
