import { Type } from 'class-transformer';
import { IsIn, IsInt, Max, Min } from 'class-validator';

export class MigrationOffsetPageDto {
  @Type(() => Number)
  @IsInt()
  @Min(0)
  @Max(2147483547)
  offset = 0;

  @Type(() => Number)
  @IsInt()
  @Min(1)
  @Max(100)
  limit = 40;
}

export class MigrationReportPageDto extends MigrationOffsetPageDto {
  @IsIn(['matched', 'unresolved', 'duplicate', 'users'])
  kind: 'matched' | 'unresolved' | 'duplicate' | 'users' = 'matched';
}
