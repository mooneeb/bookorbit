import { IsOptional, IsString, Matches } from 'class-validator';
import type { RefreshRequest } from '@bookorbit/types';

export class RefreshDto implements RefreshRequest {
  @IsOptional()
  @IsString()
  @Matches(/^[a-f0-9]{64}$/)
  refreshToken?: string;
}
