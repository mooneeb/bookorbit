import { IsInt, IsNotEmpty, IsOptional, IsString, Matches } from 'class-validator';

export class SaveTtsPositionDto {
  @IsOptional()
  @Matches(/^[a-f0-9]{64}$/)
  baseVersion?: string;

  @IsString()
  @IsNotEmpty()
  cfi!: string;

  @IsOptional()
  @IsInt()
  chapterIndex?: number;
}
