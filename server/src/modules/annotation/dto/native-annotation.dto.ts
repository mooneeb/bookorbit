import { Type } from 'class-transformer';
import {
  ArrayMaxSize,
  IsArray,
  IsDefined,
  IsIn,
  IsInt,
  IsNotEmpty,
  IsNumber,
  IsOptional,
  IsString,
  IsUUID,
  Matches,
  Max,
  MaxLength,
  Min,
  ValidateNested,
} from 'class-validator';
import type {
  NativeAnnotationAck,
  NativeAnnotationDrawing,
  NativeAnnotationKind,
  NativeAnnotationOperation,
  NativeAnnotationOperationsRequest,
  NativeAnnotationPayload,
  NativeInkPoint,
  NativeInkStroke,
} from '@bookorbit/types';
import { CreateAnnotationRectDto } from './create-annotation.dto';
import { ANNOTATION_STYLES } from '../annotation.constants';

class InkPointDto implements NativeInkPoint {
  @IsNumber() x!: number;
  @IsNumber() y!: number;
  @IsOptional() @IsNumber() @Min(0) @Max(1) pressure?: number;
}
class InkStrokeDto implements NativeInkStroke {
  @IsString() @IsNotEmpty() @MaxLength(100) id!: string;
  @IsArray() @ArrayMaxSize(10000) @ValidateNested({ each: true }) @Type(() => InkPointDto) points!: InkPointDto[];
  @IsString() @Matches(/^#[0-9a-f]{6}$/i) color!: string;
  @IsNumber() @Min(0.01) @Max(100) width!: number;
}
class InkDrawingDto implements NativeAnnotationDrawing {
  @IsIn(['bookorbit-ink-v1']) format!: 'bookorbit-ink-v1';
  @IsArray() @ArrayMaxSize(1000) @ValidateNested({ each: true }) @Type(() => InkStrokeDto) strokes!: InkStrokeDto[];
  @IsOptional() @IsString() @MaxLength(2000000) nativeData?: string;
}
class NativeAnnotationPdfDto {
  @IsInt() @Min(0) page!: number;
  @IsDefined() @ValidateNested() @Type(() => CreateAnnotationRectDto) rect!: CreateAnnotationRectDto;
  @IsArray() @ArrayMaxSize(500) @ValidateNested({ each: true }) @Type(() => CreateAnnotationRectDto) rects!: CreateAnnotationRectDto[];
}
export class NativeAnnotationPayloadDto implements NativeAnnotationPayload {
  @IsOptional() @IsString() @MaxLength(2000) cfi?: string;
  @IsOptional() @ValidateNested() @Type(() => NativeAnnotationPdfDto) pdf?: NativeAnnotationPdfDto;
  @IsOptional() @IsInt() @Min(1) bookFileId?: number;
  @IsOptional() @IsString() @MaxLength(10000) text?: string;
  @IsOptional() @IsString() @MaxLength(20) color?: string;
  @IsOptional() @IsIn(ANNOTATION_STYLES) style?: string;
  @IsOptional() @IsString() @MaxLength(10000) note?: string | null;
  @IsOptional() @IsString() @MaxLength(500) chapterTitle?: string | null;
  @IsOptional() @IsIn(['highlight', 'text_note', 'handwriting', 'pdf_ink']) kind?: NativeAnnotationKind;
  @IsOptional() @ValidateNested() @Type(() => InkDrawingDto) drawing?: InkDrawingDto | null;
  @IsOptional() @IsString() @MaxLength(128) sourceRevision?: string | null;
  @IsOptional() @IsString() @MaxLength(128) pageFingerprint?: string | null;
}
export class NativeAnnotationOperationDto implements NativeAnnotationOperation {
  @IsUUID() operationId!: string;
  @IsUUID() clientId!: string;
  @IsOptional() @IsInt() @Min(1) annotationId?: number;
  @IsInt() @Min(1) bookId!: number;
  @IsInt() @Min(0) baseVersion!: number;
  @IsIn(['create', 'update', 'delete', 'restore', 'repair']) action!: NativeAnnotationOperation['action'];
  @IsOptional() @ValidateNested() @Type(() => NativeAnnotationPayloadDto) payload?: NativeAnnotationPayloadDto;
}
export class NativeAnnotationOperationsDto implements NativeAnnotationOperationsRequest {
  @IsString() @IsNotEmpty() @MaxLength(100) deviceId!: string;
  @IsArray() @ArrayMaxSize(100) @ValidateNested({ each: true }) @Type(() => NativeAnnotationOperationDto) operations!: NativeAnnotationOperationDto[];
}
export class NativeAnnotationDeltaQueryDto {
  @IsOptional() @Type(() => Number) @IsInt() @Min(1) bookId?: number;
  @IsOptional() @IsString() @Matches(/^\d{1,15}$/) cursor?: string;
  @IsOptional() @Type(() => Number) @IsInt() @Min(1) @Max(100) limit?: number;
}
export class NativeAnnotationAckDto implements NativeAnnotationAck {
  @IsString() @IsNotEmpty() @MaxLength(100) deviceId!: string;
  @IsInt() @Min(1) bookId!: number;
  @IsString() @Matches(/^\d{1,15}$/) cursor!: string;
}
