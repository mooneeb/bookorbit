import { IsBoolean, IsOptional, IsString, MaxLength } from 'class-validator';

export class UpsertReadwiseSettingsDto {
  @IsOptional()
  @IsString()
  @MaxLength(2048)
  apiToken?: string;

  @IsOptional()
  @IsBoolean()
  enabled?: boolean;

  @IsOptional()
  @IsBoolean()
  includeExistingHighlights?: boolean;
}

export class ValidateReadwiseTokenDto {
  @IsOptional()
  @IsString()
  @MaxLength(2048)
  token?: string;
}
