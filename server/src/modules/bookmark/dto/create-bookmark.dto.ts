import { IsNotEmpty, IsString, MaxLength } from 'class-validator';
import type { CreateEpubBookmarkPayload } from '@bookorbit/types';

export class CreateBookmarkDto implements CreateEpubBookmarkPayload {
  @IsString()
  @IsNotEmpty()
  @MaxLength(2000)
  cfi!: string;

  @IsString()
  @IsNotEmpty()
  @MaxLength(500)
  title!: string;
}
