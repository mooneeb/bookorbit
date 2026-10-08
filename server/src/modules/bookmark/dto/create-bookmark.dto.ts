import { IsNotEmpty, IsOptional, IsString, IsUUID, MaxLength } from 'class-validator';
import type { CreateEpubBookmarkPayload } from '@bookorbit/types';

export class CreateBookmarkDto implements CreateEpubBookmarkPayload {
  @IsOptional()
  @IsUUID()
  clientId?: string;

  @IsString()
  @IsNotEmpty()
  @MaxLength(2000)
  cfi!: string;

  @IsString()
  @IsNotEmpty()
  @MaxLength(500)
  title!: string;
}
