import { Type } from 'class-transformer';
import { IsInt, IsOptional, IsString, Matches, Max, Min } from 'class-validator';

export class SourcePdfPageQueryDto {
  @Type(() => Number) @IsInt() @Min(1) bookId!: number;
  @Type(() => Number) @IsOptional() @IsInt() @Min(0) page?: number;
  @Type(() => Number) @IsOptional() @IsInt() @Min(0) pageStart?: number;
  @Type(() => Number) @IsOptional() @IsInt() @Min(1) @Max(100) limit?: number;
  @IsOptional() @IsString() @Matches(/^sha256:[a-f0-9]{64}$/) sourceRevision?: string;
}
