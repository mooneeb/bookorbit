import {
  Allow,
  ArrayMaxSize,
  ArrayNotEmpty,
  IsArray,
  IsDefined,
  IsIn,
  IsInt,
  IsISO8601,
  IsObject,
  IsOptional,
  IsString,
  Min,
  ValidateIf,
  ValidateNested,
} from 'class-validator';
import type {
  BulkArrayEdit,
  BulkStringEdit,
  BulkNumberEdit,
  BulkMetadataEditFields,
  BulkMetadataVersion,
  CustomMetadataBookValueInput,
  CustomMetadataPrimitiveValue,
} from '@bookorbit/types';
import { Type } from 'class-transformer';
import { BulkSelectionDto } from './bulk-selection.dto';
import { BookSeriesMembershipDto } from './update-book-metadata.dto';

const ARRAY_MODES = ['add', 'remove', 'replace'] as const;
export type BulkArrayMode = BulkArrayEdit['mode'];

export class BulkArrayFieldDto implements BulkArrayEdit {
  @IsIn(ARRAY_MODES)
  mode!: BulkArrayMode;

  @IsArray()
  @ArrayMaxSize(1000)
  @IsString({ each: true })
  values!: string[];
}

export class BulkScalarStringFieldDto implements BulkStringEdit {
  @ValidateIf((_dto, value) => value !== null)
  @IsString()
  value!: string | null;
}

export class BulkScalarNumberFieldDto implements BulkNumberEdit {
  @ValidateIf((_dto, value) => value !== null)
  @IsInt()
  value!: number | null;
}

const ALLOWED_FIELD_KEYS = new Set<string>([
  'authors',
  'seriesName',
  'seriesMemberships',
  'genres',
  'tags',
  'publisher',
  'language',
  'publishedYear',
  'narrators',
  'customMetadata',
]);

export class BulkCustomMetadataValueDto implements CustomMetadataBookValueInput {
  @IsInt()
  @Min(1)
  fieldId!: number;

  @ValidateIf((_dto, value) => value !== null)
  @IsDefined()
  @Allow()
  value!: CustomMetadataPrimitiveValue;
}

export class BulkEditFieldsDto implements BulkMetadataEditFields {
  @ValidateIf((_dto, value) => value !== undefined)
  @IsArray()
  @ArrayNotEmpty()
  @ArrayMaxSize(100)
  @ValidateNested({ each: true })
  @Type(() => BulkCustomMetadataValueDto)
  customMetadata?: BulkCustomMetadataValueDto[];

  @IsOptional()
  @ValidateNested()
  @Type(() => BulkArrayFieldDto)
  authors?: BulkArrayFieldDto;

  @IsOptional()
  @ValidateNested()
  @Type(() => BulkScalarStringFieldDto)
  seriesName?: BulkScalarStringFieldDto;

  @IsOptional()
  @IsArray()
  @ValidateNested({ each: true })
  @Type(() => BookSeriesMembershipDto)
  seriesMemberships?: BookSeriesMembershipDto[];

  @IsOptional()
  @ValidateNested()
  @Type(() => BulkArrayFieldDto)
  genres?: BulkArrayFieldDto;

  @IsOptional()
  @ValidateNested()
  @Type(() => BulkArrayFieldDto)
  tags?: BulkArrayFieldDto;

  @IsOptional()
  @ValidateNested()
  @Type(() => BulkScalarStringFieldDto)
  publisher?: BulkScalarStringFieldDto;

  @IsOptional()
  @ValidateNested()
  @Type(() => BulkScalarStringFieldDto)
  language?: BulkScalarStringFieldDto;

  @IsOptional()
  @ValidateNested()
  @Type(() => BulkScalarNumberFieldDto)
  publishedYear?: BulkScalarNumberFieldDto;

  @IsOptional()
  @ValidateNested()
  @Type(() => BulkArrayFieldDto)
  narrators?: BulkArrayFieldDto;

  hasAtLeastOneField(): boolean {
    return Object.keys(this).some((k) => ALLOWED_FIELD_KEYS.has(k) && (this as Record<string, unknown>)[k] !== undefined);
  }

  hasOnlyAllowedKeys(rawInput: Record<string, unknown>): boolean {
    return Object.keys(rawInput).every((k) => ALLOWED_FIELD_KEYS.has(k));
  }

  hasValidArrayValues(): boolean {
    for (const key of ['authors', 'genres', 'tags', 'narrators'] as const) {
      const field = this[key];
      if (!field) continue;
      if ((field.mode === 'add' || field.mode === 'remove') && (!field.values || field.values.length === 0)) {
        return false;
      }
    }
    return true;
  }
}

export { ALLOWED_FIELD_KEYS as BULK_EDIT_ALLOWED_FIELD_KEYS };

export class BulkMetadataVersionDto implements BulkMetadataVersion {
  @IsInt()
  @Min(1)
  bookId!: number;

  @IsISO8601()
  updatedAt!: string;
}

export class BulkEditMetadataDto extends BulkSelectionDto {
  @IsOptional()
  @IsArray()
  @ArrayMaxSize(100)
  @ValidateNested({ each: true })
  @Type(() => BulkMetadataVersionDto)
  expectedVersions?: BulkMetadataVersionDto[];

  @IsObject()
  @ValidateNested()
  @Type(() => BulkEditFieldsDto)
  fields!: BulkEditFieldsDto;
}
