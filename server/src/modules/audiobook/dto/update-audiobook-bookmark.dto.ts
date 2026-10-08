import type { UpdateAudiobookBookmark } from '@bookorbit/types';
import { IsNotEmpty, IsOptional, IsString, MaxLength } from 'class-validator';

export class UpdateAudiobookBookmarkDto implements UpdateAudiobookBookmark {
  @IsOptional()
  @IsString()
  @IsNotEmpty()
  @MaxLength(500)
  title?: string;

  @IsOptional()
  @IsString()
  @MaxLength(4000)
  note?: string | null;
}
