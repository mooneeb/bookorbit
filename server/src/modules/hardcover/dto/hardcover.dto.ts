import { ArrayMaxSize, ArrayUnique, IsArray, IsBoolean, IsIn, IsInt, IsOptional, IsString, Max, MaxLength, Min } from 'class-validator';

import type {
  ApplyHardcoverImportPayload,
  PreviewHardcoverImportPayload,
  SetHardcoverEditionPayload,
  UpdateHardcoverBookSyncPayload,
} from '@bookorbit/types';

export class UpsertHardcoverSettingsDto {
  @IsOptional()
  @IsString()
  @MaxLength(2048)
  apiToken?: string;

  @IsOptional()
  @IsBoolean()
  enabled?: boolean;

  @IsOptional()
  @IsIn(['all_eligible', 'selected_only'])
  bookSyncMode?: 'all_eligible' | 'selected_only';

  @IsOptional()
  @IsBoolean()
  autoSyncOnStatusChange?: boolean;

  @IsOptional()
  @IsBoolean()
  autoSyncOnProgressUpdate?: boolean;

  @IsOptional()
  @IsBoolean()
  autoSyncOnRatingChange?: boolean;

  @IsOptional()
  @IsInt()
  @IsIn([1, 2, 3])
  privacySettingId?: number;
}

export class ValidateHardcoverTokenDto {
  @IsOptional()
  @IsString()
  @MaxLength(2048)
  token?: string;
}

export class UpdateHardcoverBookSyncDto implements UpdateHardcoverBookSyncPayload {
  @IsBoolean()
  syncEnabled!: boolean;
}

export class SetHardcoverEditionDto implements SetHardcoverEditionPayload {
  @IsInt()
  @Min(1)
  editionId!: number;
}

export class PreviewHardcoverImportDto implements PreviewHardcoverImportPayload {
  @IsOptional()
  @IsInt()
  @Min(0)
  @Max(2_147_483_647)
  afterId?: number;
}

export class ApplyHardcoverImportDto extends PreviewHardcoverImportDto implements ApplyHardcoverImportPayload {
  @IsOptional()
  @IsArray()
  @ArrayUnique()
  @ArrayMaxSize(100)
  @IsInt({ each: true })
  @Min(1, { each: true })
  hardcoverUserBookIds?: number[];

  @IsOptional()
  @IsBoolean()
  importProgress?: boolean;
}
