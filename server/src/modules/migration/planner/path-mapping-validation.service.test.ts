import { describe, expect, it, vi } from 'vitest';
import { Test } from '@nestjs/testing';

import type { SourceBook } from '../adapters/source-adapter.types';
import { MigrationRepository } from '../migration.repository';
import { PathMappingValidationService } from './path-mapping-validation.service';

async function createService(existingPaths: string[]) {
  const existing = new Set(existingPaths);
  const repo = {
    findExistingBookFilePaths: vi.fn((paths: string[]) => Promise.resolve(new Set(paths.filter((path) => existing.has(path))))),
  };
  const module = await Test.createTestingModule({
    providers: [PathMappingValidationService, { provide: MigrationRepository, useValue: repo }],
  }).compile();
  return { service: module.get(PathMappingValidationService), repo };
}

function sourceBook(path: string | null, filePaths: string[] = []): SourceBook {
  return {
    sourceBookId: path ?? 'files-only',
    title: null,
    author: null,
    subtitle: null,
    isbn10: null,
    isbn13: null,
    description: null,
    publisher: null,
    publishedYear: null,
    language: null,
    filePath: path,
    fileHash: null,
    genres: [],
    tags: [],
    files: filePaths.map((filePath, index) => ({
      sourceFileId: String(index),
      sourceBookId: path ?? 'files-only',
      filePath,
      fileHash: null,
      fileName: null,
      fileSubPath: null,
      durationSeconds: null,
    })),
  };
}

describe('PathMappingValidationService', () => {
  it('computes summary and mapping stats against target file paths', async () => {
    const { service } = await createService(['/target/library/book-1.epub']);

    const result = await service.validate({
      sourceBooks: [
        {
          sourceBookId: '1',
          title: null,
          author: null,
          subtitle: null,
          isbn10: null,
          isbn13: null,
          description: null,
          publisher: null,
          publishedYear: null,
          language: null,
          filePath: '/source/library/book-1.epub',
          fileHash: null,
          genres: [],
          tags: [],
        },
        {
          sourceBookId: '2',
          title: null,
          author: null,
          subtitle: null,
          isbn10: null,
          isbn13: null,
          description: null,
          publisher: null,
          publishedYear: null,
          language: null,
          filePath: '/source/library/book-2.epub',
          fileHash: null,
          genres: [],
          tags: [],
        },
        {
          sourceBookId: '3',
          title: null,
          author: null,
          subtitle: null,
          isbn10: null,
          isbn13: null,
          description: null,
          publisher: null,
          publishedYear: null,
          language: null,
          filePath: '/other/no-map.epub',
          fileHash: null,
          genres: [],
          tags: [],
        },
      ],
      pathMappings: [{ sourcePrefix: '/source/library', targetPrefix: '/target/library' }],
      actorUserId: 7,
      sampleLimit: 5,
    });

    expect(result.summary.booksWithFilePath).toBe(3);
    expect(result.summary.mappedByPrefix).toBe(2);
    expect(result.summary.matchedTargetPaths).toBe(1);
    expect(result.summary.unmatchedTargetPaths).toBe(2);

    expect(result.mappings).toEqual([
      {
        sourcePrefix: '/source/library',
        targetPrefix: '/target/library',
        affectedBooks: 2,
        matchedTargetPaths: 1,
        unmatchedTargetPaths: 1,
        unmatchedSamples: ['/target/library/book-2.epub'],
      },
    ]);
  });

  it.each([105, 4])('matches %i Audiobookshelf item folders through their mapped media files', async (total) => {
    const sourceBooks = Array.from({ length: total }, (_, index) =>
      sourceBook(`/e03-source/proof-${index}`, [`/e03-source/proof-${index}/proof.epub`]),
    );
    const { service, repo } = await createService(sourceBooks.map((_, index) => `/target/proof-${index}/proof.epub`));

    const result = await service.validate({
      sourceBooks,
      pathMappings: [{ sourcePrefix: '/e03-source', targetPrefix: '/target' }],
      actorUserId: 7,
      sampleLimit: 5,
    });

    expect(result.summary).toEqual({
      totalSourceBooks: total,
      booksWithFilePath: total,
      mappedByPrefix: total,
      matchedTargetPaths: total,
      unmatchedTargetPaths: 0,
      unchangedPaths: 0,
    });
    expect(result.mappings[0]).toMatchObject({ affectedBooks: total, matchedTargetPaths: total, unmatchedTargetPaths: 0, unmatchedSamples: [] });
    expect(repo.findExistingBookFilePaths).toHaveBeenCalledTimes(1);
    expect(repo.findExistingBookFilePaths).toHaveBeenCalledWith(expect.arrayContaining(['/target/proof-0/proof.epub']), 7);
  });

  it('counts a files-only book once even when several mapped files exist', async () => {
    const { service } = await createService(['/target/book/chapter-1.mp3', '/target/book/chapter-2.mp3']);
    const result = await service.validate({
      sourceBooks: [sourceBook(null, ['/source/book/chapter-1.mp3', '/source/book/chapter-2.mp3'])],
      pathMappings: [{ sourcePrefix: '/source', targetPrefix: '/target' }],
      actorUserId: 7,
    });

    expect(result.summary).toMatchObject({ totalSourceBooks: 1, booksWithFilePath: 1, matchedTargetPaths: 1, unmatchedTargetPaths: 0 });
  });

  it('keeps missing folders and unsafe paths unmatched while retaining exact file matches', async () => {
    const { service, repo } = await createService(['/target/existing/proof.mp3', '/target/../private', '/target/nul\0path']);
    const result = await service.validate({
      sourceBooks: [
        sourceBook('/source/existing/proof.mp3'),
        sourceBook('/source/missing', ['/source/missing/proof.mp3']),
        sourceBook('/source/../private'),
        sourceBook('/source/nul\0path'),
      ],
      pathMappings: [{ sourcePrefix: '/source', targetPrefix: '/target' }],
      actorUserId: 7,
      sampleLimit: 2,
    });

    expect(result.summary).toMatchObject({ matchedTargetPaths: 1, unmatchedTargetPaths: 3 });
    expect(result.mappings[0].unmatchedSamples).toEqual(['/target/missing', '/target/../private']);
    expect(repo.findExistingBookFilePaths).toHaveBeenCalledWith(['/target/existing/proof.mp3', '/target/missing', '/target/missing/proof.mp3'], 7);
  });

  it('uses the most specific mapping for media candidates without matching sibling prefixes', async () => {
    const { service } = await createService(['/specific/book/proof.pdf']);
    const result = await service.validate({
      sourceBooks: [sourceBook('/source/special/book', ['/source/special/book/proof.pdf']), sourceBook('/source-other/missing')],
      pathMappings: [
        { sourcePrefix: '/source/', targetPrefix: '/target/' },
        { sourcePrefix: '/source/special', targetPrefix: '/specific' },
      ],
      actorUserId: 7,
    });

    expect(result.summary).toMatchObject({ mappedByPrefix: 1, matchedTargetPaths: 1, unmatchedTargetPaths: 1, unchangedPaths: 1 });
    expect(result.mappings[0]).toMatchObject({ targetPrefix: '/specific', matchedTargetPaths: 1 });
  });
});
