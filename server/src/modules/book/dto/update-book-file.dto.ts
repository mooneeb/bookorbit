import type { UpdateBookFilePayload } from '@bookorbit/types';
import { IsString, IsOptional, IsNotEmpty } from 'class-validator';

export class UpdateBookFileDto implements UpdateBookFilePayload {
  @IsString()
  @IsNotEmpty()
  @IsOptional()
  filename?: string;
}
