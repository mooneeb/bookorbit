import { Type } from 'class-transformer';
import { IsIn, IsInt, Max, Min } from 'class-validator';

export class MigrationPlanPageDto {
  @IsIn(['matched', 'unresolved', 'duplicate'])
  kind: 'matched' | 'unresolved' | 'duplicate' = 'matched';

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
