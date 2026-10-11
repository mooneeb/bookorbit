import { IsDateString, IsIn, IsInt, IsNumber, IsOptional, IsString, Max, MaxLength, Min, MinLength } from 'class-validator';
import { CLIENT_READING_SESSION_SOURCES, type ClientReadingSessionSource } from '@bookorbit/types';

export class SaveReadingSessionDto {
  @IsOptional()
  @IsInt()
  @Min(1)
  @Max(2_147_483_647)
  attemptId?: number | null;

  @IsString()
  @MinLength(1)
  @MaxLength(64)
  sessionId!: string;

  @IsDateString()
  startedAt!: string;

  @IsDateString()
  endedAt!: string;

  // Client-computed from active reading time (excludes idle and tab-hidden periods).
  // Server validates it does not exceed the wall-clock span of the session.
  @IsInt()
  @Min(0)
  @Max(86400)
  durationSeconds!: number;

  // Nullable: can be negative if the user navigated backward.
  @IsOptional()
  @IsNumber()
  @Min(-100)
  @Max(100)
  progressDelta?: number | null;

  @IsOptional()
  @IsNumber()
  @Min(0)
  @Max(100)
  endProgress?: number | null;

  @IsOptional()
  @IsString()
  @IsIn(['read', 'tts', 'listen'])
  sessionType?: 'read' | 'tts' | 'listen';

  // Browser clients omit this field. Native clients may report only their own
  // first-party platform; integration and manual sources remain server-owned.
  @IsOptional()
  @IsString()
  @IsIn(CLIENT_READING_SESSION_SOURCES)
  source?: ClientReadingSessionSource;
}
