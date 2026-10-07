import { Type } from 'class-transformer';
import { IsIn, IsInt, IsOptional, IsString, Matches, Max, MaxLength, Min } from 'class-validator';
import type { BookContinuationDirection, BookContinuationQuery } from '@bookorbit/types';

export class BookContinuationQueryDto implements BookContinuationQuery {
  @IsIn(['text_to_audio', 'audio_to_text'])
  direction!: BookContinuationDirection;

  @Type(() => Number)
  @IsInt()
  @Min(1)
  @Max(Number.MAX_SAFE_INTEGER)
  sourceFileId!: number;

  @IsOptional()
  @IsString()
  @MaxLength(2000)
  @Matches(/^epubcfi\(/)
  textCfi?: string;

  @IsOptional()
  @Type(() => Number)
  @IsInt()
  @Min(1)
  @Max(Number.MAX_SAFE_INTEGER)
  audioRevision?: number;
}
