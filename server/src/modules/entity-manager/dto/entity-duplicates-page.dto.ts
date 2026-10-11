import { Type } from 'class-transformer';
import { IsInt, IsString, Max, MaxLength, Min } from 'class-validator';

export class EntityDuplicatesPageDto {
  @Type(() => Number)
  @IsInt()
  @Min(1)
  page = 1;

  @Type(() => Number)
  @IsInt()
  @Min(1)
  @Max(100)
  pageSize = 20;
}

export class EntityDuplicateClusterPageDto extends EntityDuplicatesPageDto {
  @IsString()
  @MaxLength(2000)
  clusterId!: string;
}
