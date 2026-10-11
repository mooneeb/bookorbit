import { Transform } from 'class-transformer';
import {
  ArrayMaxSize,
  ArrayMinSize,
  IsArray,
  IsBoolean,
  IsIn,
  IsInt,
  IsNumber,
  IsOptional,
  IsString,
  Max,
  MaxLength,
  Min,
  ValidateIf,
} from 'class-validator';

export class ScanDuplicatesDto {
  @IsOptional()
  @IsNumber()
  @Transform(({ value }) => (value !== undefined ? Number(value) : undefined))
  libraryId?: number;

  @IsOptional()
  @IsNumber()
  @Min(0.1)
  @Max(1.0)
  @Transform(({ value }) => (value !== undefined ? Number(value) : undefined))
  minSimilarity?: number;

  @IsOptional()
  @IsInt()
  @Min(1)
  @Transform(({ value }) => (value !== undefined ? Number(value) : undefined))
  page?: number;

  @IsOptional()
  @IsInt()
  @Min(1)
  @Max(100)
  @Transform(({ value }) => (value !== undefined ? Number(value) : undefined))
  pageSize?: number;
}

export class BrowseEntitiesDto {
  @IsOptional()
  @IsString()
  search?: string;

  @IsOptional()
  @IsInt()
  @Min(1)
  @Transform(({ value }) => (value !== undefined ? Number(value) : undefined))
  page?: number;

  @IsOptional()
  @IsInt()
  @Min(1)
  @Max(100)
  @Transform(({ value }) => (value !== undefined ? Number(value) : undefined))
  pageSize?: number;

  @IsOptional()
  @IsIn(['name', 'bookCount'])
  sortBy?: string;

  @IsOptional()
  @IsIn(['asc', 'desc'])
  sortOrder?: string;

  @IsOptional()
  @IsIn(['any', 'empty'])
  bookCount?: string;
}

export class MergeEntitiesDto {
  @ValidateIf((dto: MergeEntitiesDto) => dto.targetValue === undefined || dto.targetEntityId !== undefined)
  @IsInt()
  @Min(1)
  targetEntityId?: number;

  @ValidateIf((dto: MergeEntitiesDto) => dto.targetEntityId === undefined || dto.targetValue !== undefined)
  @IsString()
  targetValue?: string;

  @ValidateIf((dto: MergeEntitiesDto) => dto.targetValue === undefined || dto.sourceEntityIds !== undefined)
  @IsArray()
  @ArrayMinSize(1)
  @ArrayMaxSize(100)
  @IsInt({ each: true })
  @Min(1, { each: true })
  sourceEntityIds?: number[];

  @ValidateIf((dto: MergeEntitiesDto) => dto.targetEntityId === undefined || dto.sourceValues !== undefined)
  @IsArray()
  @ArrayMinSize(1)
  @ArrayMaxSize(100)
  @IsString({ each: true })
  @MaxLength(500, { each: true })
  sourceValues?: string[];

  @IsOptional()
  @IsBoolean()
  writeFiles?: boolean;
}

export class RenameEntityDto {
  @IsOptional()
  @IsInt()
  @Min(1)
  entityId?: number;

  @IsOptional()
  @IsString()
  currentValue?: string;

  @IsString()
  @MaxLength(500)
  newName!: string;

  @IsOptional()
  @IsBoolean()
  writeFiles?: boolean;
}

export class DeleteEntityDto {
  @IsOptional()
  @IsInt()
  @Min(1)
  @Transform(({ value }) => (typeof value === 'string' ? Number(value) : value))
  entityId?: number;

  @IsOptional()
  @IsString()
  value?: string;

  @IsOptional()
  @IsIn(['soft', 'hard', 'inline'])
  mode?: 'soft' | 'hard' | 'inline';

  @IsOptional()
  @IsBoolean()
  writeFiles?: boolean;
}

export class BulkDeleteEntitiesDto {
  @IsOptional()
  @IsArray()
  @ArrayMinSize(1)
  @ArrayMaxSize(100)
  @IsInt({ each: true })
  @Min(1, { each: true })
  entityIds?: number[];

  @IsOptional()
  @IsArray()
  @ArrayMinSize(1)
  @ArrayMaxSize(100)
  @IsString({ each: true })
  @MaxLength(500, { each: true })
  values?: string[];

  @IsOptional()
  @IsIn(['soft', 'hard', 'inline'])
  mode?: 'soft' | 'hard' | 'inline';

  @IsOptional()
  @IsBoolean()
  writeFiles?: boolean;
}

export class SplitEntityDto {
  @IsInt()
  @Min(1)
  entityId!: number;

  @IsArray()
  @ArrayMinSize(2)
  @ArrayMaxSize(100)
  @IsString({ each: true })
  @MaxLength(500, { each: true })
  newNames!: string[];

  @IsOptional()
  @IsBoolean()
  writeFiles?: boolean;
}

export class DismissPairDto {
  @IsOptional()
  @IsInt()
  @Min(1)
  entityIdA?: number;

  @IsOptional()
  @IsInt()
  @Min(1)
  entityIdB?: number;

  @IsOptional()
  @IsString()
  valueA?: string;

  @IsOptional()
  @IsString()
  valueB?: string;

  @IsOptional()
  @IsString()
  reason?: string;
}

export class UndismissPairDto {
  @IsOptional()
  @IsInt()
  @Min(1)
  entityIdA?: number;

  @IsOptional()
  @IsInt()
  @Min(1)
  entityIdB?: number;

  @IsOptional()
  @IsString()
  valueA?: string;

  @IsOptional()
  @IsString()
  valueB?: string;
}

export class RefreshDuplicatesDto {
  @IsOptional()
  @IsNumber()
  @Min(0.1)
  @Max(1.0)
  @Transform(({ value }) => (value !== undefined ? Number(value) : undefined))
  minSimilarity?: number;
}
