import { IsNumber, IsOptional, IsString, Max, Min } from 'class-validator';
import type { TtsPreferencesPatch } from '@bookorbit/types';

export class UpdateTtsPreferencesDto implements TtsPreferencesPatch {
  @IsOptional()
  @IsString()
  providerId?: string;

  @IsOptional()
  @IsString()
  voiceId?: string;

  @IsOptional()
  @IsNumber()
  @Min(0.25)
  @Max(4)
  speed?: number;
}
