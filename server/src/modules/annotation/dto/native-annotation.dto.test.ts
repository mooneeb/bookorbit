import 'reflect-metadata';
import { BadRequestException, ValidationPipe } from '@nestjs/common';
import { NativeAnnotationAckDto, NativeAnnotationDeltaQueryDto, NativeAnnotationOperationsDto } from './native-annotation.dto';

const pipe = new ValidationPipe({ whitelist: true, forbidNonWhitelisted: true, transform: true });
const operation = {
  operationId: 'd65285d5-e052-428f-bb2d-44c1a74432e4',
  clientId: '7d2bcd62-aa64-4a39-b69f-4e2ef63c39bd',
  bookId: 9,
  baseVersion: 0,
  action: 'create',
  payload: {
    kind: 'pdf_ink',
    bookFileId: 10,
    pdf: { page: 0, rect: { x: 1, y: 2, width: 3, height: 4 }, rects: [{ x: 1, y: 2, width: 3, height: 4 }] },
    drawing: {
      format: 'bookorbit-ink-v1',
      strokes: [{ id: 'stroke-1', points: [{ x: 1, y: 2, pressure: 0.5 }], color: '#12ABef', width: 2 }],
      nativeData: 'retained-native-data',
    },
    sourceRevision: 'revision-1',
    pageFingerprint: 'page-1',
  },
};
function transform(metatype: new () => object, value: object) {
  return pipe.transform(value, { type: 'body', metatype });
}

describe('Native annotation request boundaries', () => {
  it('transforms and validates the nested source ink protocol', async () => {
    const dto = await transform(NativeAnnotationOperationsDto, { deviceId: 'ipad', operations: [operation] });
    expect(dto).toBeInstanceOf(NativeAnnotationOperationsDto);
    expect(dto).toEqual({ deviceId: 'ipad', operations: [operation] });
    expect(dto.operations[0].payload.drawing.strokes[0].points[0].constructor.name).toBe('InkPointDto');
  });
  it.each([{ operationId: 'not-a-uuid' }, { baseVersion: -1 }, { baseVersion: 1.2 }, { bookId: 0 }, { action: 'overwrite' }, { unknown: true }])(
    'rejects invalid operation identities, versions, actions and unknown fields: %j',
    async (patch) => {
      await expect(transform(NativeAnnotationOperationsDto, { deviceId: 'ipad', operations: [{ ...operation, ...patch }] })).rejects.toBeInstanceOf(
        BadRequestException,
      );
    },
  );
  it.each([
    { drawing: { ...operation.payload.drawing, format: 'ink-v2' } },
    { drawing: { ...operation.payload.drawing, strokes: [{ ...operation.payload.drawing.strokes[0], color: 'red' }] } },
    { drawing: { ...operation.payload.drawing, strokes: [{ ...operation.payload.drawing.strokes[0], width: 0 }] } },
    { drawing: { ...operation.payload.drawing, strokes: [{ ...operation.payload.drawing.strokes[0], points: [{ x: 1, y: 2, pressure: 1.1 }] }] } },
    { drawing: { ...operation.payload.drawing, strokes: [{ ...operation.payload.drawing.strokes[0], points: [{ x: '1', y: 2 }] }] } },
    { pdf: { ...operation.payload.pdf, page: -1 } },
    { pdf: { page: 0, rects: [] } },
    { pdf: { ...operation.payload.pdf, rect: { x: 1, y: 2, width: 0, height: 4 } } },
    { sourceRevision: 'x'.repeat(129) },
    { pageFingerprint: 'x'.repeat(129) },
  ])('rejects malformed nested drawing, anchors and revision fields: %j', async (payload) => {
    await expect(
      transform(NativeAnnotationOperationsDto, { deviceId: 'ipad', operations: [{ ...operation, payload: { ...operation.payload, ...payload } }] }),
    ).rejects.toBeInstanceOf(BadRequestException);
  });
  it('bounds batches, strokes and point arrays', async () => {
    await expect(transform(NativeAnnotationOperationsDto, { deviceId: 'ipad', operations: Array(101).fill(operation) })).rejects.toBeInstanceOf(
      BadRequestException,
    );
    for (const strokes of [
      Array(1001).fill(operation.payload.drawing.strokes[0]),
      [{ ...operation.payload.drawing.strokes[0], points: Array(10001).fill({ x: 1, y: 2 }) }],
    ]) {
      await expect(
        transform(NativeAnnotationOperationsDto, {
          deviceId: 'ipad',
          operations: [{ ...operation, payload: { ...operation.payload, drawing: { ...operation.payload.drawing, strokes } } }],
        }),
      ).rejects.toBeInstanceOf(BadRequestException);
    }
  });
  it('accepts nullable private fields and passage operations', async () => {
    const payload = {
      cfi: 'epubcfi(/6/4)',
      kind: 'text_note',
      note: null,
      chapterTitle: null,
      color: 'yellow',
      style: 'underline',
      text: 'passage',
      drawing: null,
      sourceRevision: null,
      pageFingerprint: null,
    };
    expect(await transform(NativeAnnotationOperationsDto, { deviceId: 'ipad', operations: [{ ...operation, payload }] })).toMatchObject({
      operations: [{ payload }],
    });
  });
  it('coerces pagination numbers while preserving decimal cursors', async () => {
    expect(await transform(NativeAnnotationDeltaQueryDto, { bookId: '9', limit: '100', cursor: '999999999999999' })).toEqual({
      bookId: 9,
      limit: 100,
      cursor: '999999999999999',
    });
    await expect(transform(NativeAnnotationDeltaQueryDto, { limit: '101' })).rejects.toBeInstanceOf(BadRequestException);
    await expect(transform(NativeAnnotationDeltaQueryDto, { cursor: '-1' })).rejects.toBeInstanceOf(BadRequestException);
    await expect(transform(NativeAnnotationDeltaQueryDto, { cursor: '9999999999999999' })).rejects.toBeInstanceOf(BadRequestException);
  });
  it('accepts checkpoints and rejects unknown ack fields or non-decimal cursors', async () => {
    expect(await transform(NativeAnnotationAckDto, { deviceId: 'ipad', bookId: 9, cursor: '0' })).toEqual({
      deviceId: 'ipad',
      bookId: 9,
      cursor: '0',
    });
    await expect(transform(NativeAnnotationAckDto, { deviceId: 'ipad', bookId: 9, cursor: '1e3' })).rejects.toBeInstanceOf(BadRequestException);
    await expect(transform(NativeAnnotationAckDto, { deviceId: 'ipad', bookId: 9, cursor: '1', userId: 8 })).rejects.toBeInstanceOf(
      BadRequestException,
    );
  });
});
