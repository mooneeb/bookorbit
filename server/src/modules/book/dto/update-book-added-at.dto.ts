import { IsString, Matches } from 'class-validator';
import type { BookAddedAtUpdatePayload } from '@bookorbit/types';

export class UpdateBookAddedAtDto implements BookAddedAtUpdatePayload {
  @IsString() @Matches(/^\d{4}-\d{2}-\d{2}$/) addedAt!: string;
}
