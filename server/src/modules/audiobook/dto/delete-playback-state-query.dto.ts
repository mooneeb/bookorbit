import type { DeleteAudiobookPlaybackStateQuery } from '@bookorbit/types';
import { Transform } from 'class-transformer';
import { IsInt, Matches, Max, Min, ValidateIf } from 'class-validator';

export class DeletePlaybackStateQueryDto implements DeleteAudiobookPlaybackStateQuery {
  @ValidateIf((query: DeletePlaybackStateQueryDto) => query.baseRevision !== undefined || query.manifestRevision !== undefined)
  @Transform(({ value }: { value: unknown }) => (typeof value === 'string' && /^(0|[1-9][0-9]*)$/.test(value) ? Number(value) : value))
  @IsInt()
  @Min(0)
  @Max(Number.MAX_SAFE_INTEGER)
  baseRevision?: number;

  @ValidateIf((query: DeletePlaybackStateQueryDto) => query.baseRevision !== undefined || query.manifestRevision !== undefined)
  @Matches(/^[a-f0-9]{64}$/)
  manifestRevision?: string;
}
