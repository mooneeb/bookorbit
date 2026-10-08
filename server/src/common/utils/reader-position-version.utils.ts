import { createHash } from 'node:crypto';
import type { FileProgressSource } from '@bookorbit/types';
import type { ReadingProgress, TtsReadingPosition } from '../../db/schema';

export function filePositionVersion(userId: number, fileId: number, source: FileProgressSource, row: ReadingProgress | null | undefined): string {
  const position =
    source === 'narration'
      ? [
          row?.mediaOverlayFragment ?? null,
          row?.mediaOverlaySectionIndex ?? null,
          row?.positionSeconds ?? null,
          row?.narrationPercentage ?? null,
          row?.narrationUpdatedAt?.toISOString() ?? null,
        ]
      : [row?.cfi ?? null, row?.pageNumber ?? null, row?.percentage ?? 0, row?.textUpdatedAt?.toISOString() ?? null];
  return createHash('sha256')
    .update(JSON.stringify([userId, fileId, source, position]))
    .digest('hex');
}

export function speechPositionVersion(userId: number, fileId: number, row: TtsReadingPosition | null | undefined): string {
  return createHash('sha256')
    .update(JSON.stringify([userId, fileId, 'tts', row?.cfi ?? null, row?.chapterIndex ?? null, row?.updatedAt?.toISOString() ?? null]))
    .digest('hex');
}
