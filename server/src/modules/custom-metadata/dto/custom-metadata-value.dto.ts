import { Allow, IsInt, Min } from 'class-validator';
import type { CustomMetadataBookValueInput, CustomMetadataPrimitiveValue } from '@bookorbit/types';

export class CustomMetadataValueDto implements CustomMetadataBookValueInput {
  @IsInt()
  @Min(1)
  fieldId!: number;

  @Allow()
  value!: CustomMetadataPrimitiveValue;
}
