import { ConflictException, BadRequestException, Injectable } from '@nestjs/common';
import { createHash } from 'crypto';
import { createReadStream } from 'fs';
import { copyFile, link, lstat, mkdir, open, realpath, stat, unlink } from 'fs/promises';
import { constants } from 'fs';
import { dirname, isAbsolute, join, relative, resolve, sep } from 'path';

export interface BookDockPublication {
  sourcePath: string;
  destPath: string;
  stagingPath: string;
  hash: string;
}

@Injectable()
export class BookDockPublicationService {
  async prepare(files: Array<{ sourcePath: string; destPath: string }>, root: string, fileId: number): Promise<BookDockPublication[]> {
    const plans: BookDockPublication[] = [];
    for (const [index, file] of files.entries()) {
      await this.validateDestination(file.destPath, root);
      const source = await lstat(file.sourcePath);
      if (!source.isFile() || source.isSymbolicLink()) throw new BadRequestException('Book Dock source must be a regular file');
      plans.push({
        ...file,
        stagingPath: join(dirname(file.destPath), `.bookorbit-dock-${fileId}-${index}.tmp`),
        hash: await this.hash(file.sourcePath),
      });
    }
    return plans;
  }

  async publish(plans: BookDockPublication[], root: string): Promise<void> {
    for (const plan of plans) {
      await this.validateDestination(plan.destPath, root);
      await mkdir(dirname(plan.destPath), { recursive: true });
      await this.validateDestination(plan.destPath, root);
      const staged = await lstat(plan.stagingPath).catch((error: NodeJS.ErrnoException) => {
        if (error.code !== 'ENOENT') throw error;
        return null;
      });
      if (staged && (!staged.isFile() || staged.isSymbolicLink())) throw new ConflictException('Book Dock staging file is unsafe');
      if (staged && (await this.hash(plan.stagingPath)) !== plan.hash) {
        const target = await lstat(plan.destPath).catch(() => null);
        if (target) throw new ConflictException('Book Dock staged file changed after publication');
        await unlink(plan.stagingPath);
      }
      if (!(await lstat(plan.stagingPath).catch(() => null))) {
        if ((await this.hash(plan.sourcePath)) !== plan.hash) throw new ConflictException('Book Dock source changed after review');
        await copyFile(plan.sourcePath, plan.stagingPath, constants.COPYFILE_EXCL);
        const handle = await open(plan.stagingPath, 'r+');
        try {
          await handle.sync();
        } finally {
          await handle.close();
        }
        if ((await this.hash(plan.stagingPath)) !== plan.hash) throw new ConflictException('Book Dock source changed during publication');
      }
      try {
        await link(plan.stagingPath, plan.destPath);
      } catch (error) {
        if ((error as NodeJS.ErrnoException).code !== 'EEXIST') throw error;
        const [stage, target] = await Promise.all([lstat(plan.stagingPath, { bigint: true }), lstat(plan.destPath, { bigint: true })]);
        if (!target.isFile() || target.isSymbolicLink() || stage.dev !== target.dev || stage.ino !== target.ino)
          throw new ConflictException('Book Dock destination already exists');
      }
      const directory = await open(dirname(plan.destPath), 'r');
      try {
        await directory.sync();
      } finally {
        await directory.close();
      }
    }
  }

  async cleanup(plans: BookDockPublication[]): Promise<void> {
    for (const plan of plans) {
      // A new file may occupy the original scan path after an interrupted import.
      if (
        await stat(plan.sourcePath).then(
          () => true,
          () => false,
        )
      ) {
        if ((await this.hash(plan.sourcePath)) === plan.hash) await unlink(plan.sourcePath);
      }
      await unlink(plan.stagingPath).catch((error: NodeJS.ErrnoException) => {
        if (error.code !== 'ENOENT') throw error;
      });
    }
  }

  private async validateDestination(path: string, root: string): Promise<void> {
    const rootPath = await realpath(root);
    const within = relative(resolve(root), resolve(path));
    if (!within || within === '..' || within.startsWith(`..${sep}`) || isAbsolute(within))
      throw new BadRequestException('Book Dock destination must stay inside its library folder');
    let parent = dirname(resolve(path));
    while (true) {
      try {
        const canonical = await realpath(parent);
        const resolvedWithin = relative(rootPath, canonical);
        if (resolvedWithin === '..' || resolvedWithin.startsWith(`..${sep}`) || isAbsolute(resolvedWithin))
          throw new BadRequestException('Book Dock destination resolves outside its library folder');
        return;
      } catch (error) {
        if ((error as NodeJS.ErrnoException).code !== 'ENOENT') throw error;
        parent = dirname(parent);
      }
    }
  }

  private async hash(path: string): Promise<string> {
    const hash = createHash('sha256');
    for await (const chunk of createReadStream(path)) hash.update(chunk as Buffer);
    return hash.digest('hex');
  }
}
