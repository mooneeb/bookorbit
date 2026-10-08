import { IsOptional, IsString, MaxLength } from 'class-validator';
import { PERSONAL_NOTE_MAX_LENGTH, type UpdateBookPersonalNotePayload } from '@bookorbit/types';

export class UpdatePersonalNoteDto implements UpdateBookPersonalNotePayload {
  @IsOptional()
  @IsString()
  @MaxLength(PERSONAL_NOTE_MAX_LENGTH)
  note?: string | null;
}
