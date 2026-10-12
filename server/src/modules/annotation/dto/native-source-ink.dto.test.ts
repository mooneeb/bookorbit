import 'reflect-metadata';
import { plainToInstance } from 'class-transformer';
import { validate } from 'class-validator';
import { NativeAnnotationOperationsDto } from './native-annotation.dto';
import { NativeSourceInkQueryDto, NativeSourceInkScopeDto, NativeSourceInkWindowQueryDto } from './native-source-ink.dto';

async function errorsFor<T extends object>(cls: new () => T, value: object) {
  return validate(plainToInstance(cls, value), { whitelist: true, forbidNonWhitelisted: true });
}

const scope = { bookId: '5', bookFileId: '12' };

describe('Native source ink query validation', () => {
  it('coerces URL scope and bounded numeric query fields while preserving the cursor string', async () => {
    const dto = plainToInstance(NativeSourceInkQueryDto, { ...scope, page: '0', limit: '100', cursor: '999999999999999' });
    expect(await validate(dto)).toHaveLength(0);
    expect(dto).toMatchObject({ bookId: 5, bookFileId: 12, page: 0, limit: 100, cursor: '999999999999999' });
    expect(await errorsFor(NativeSourceInkScopeDto, scope)).toEqual([]);
    expect(await errorsFor(NativeSourceInkQueryDto, scope)).toEqual([]);
  });

  it.each([
    { bookId: 0 },
    { bookId: 'nope' },
    { bookId: 1.5 },
    { bookFileId: 0 },
    { bookFileId: '' },
    { page: -1 },
    { page: 0.5 },
    { limit: 0 },
    { limit: 101 },
    { cursor: '-1' },
    { cursor: '1.2' },
    { cursor: '1000000000000000' },
    { cursor: 1 },
    { unexpected: true },
  ])('rejects invalid delta scope, cursor or pagination: %o', async (invalid) => {
    expect((await errorsFor(NativeSourceInkQueryDto, { ...scope, ...invalid })).length).toBeGreaterThan(0);
  });

  it('accepts zero-based page zero and bounded window arithmetic', async () => {
    const dto = plainToInstance(NativeSourceInkWindowQueryDto, { ...scope, page: ' 0 ', window: '2', limit: '100' });
    expect(await validate(dto)).toEqual([]);
    expect(dto).toMatchObject({ page: 0, window: 2, limit: 100 });
    expect(
      await errorsFor(NativeSourceInkWindowQueryDto, {
        ...scope,
        page: Number.MAX_SAFE_INTEGER - 1,
        window: Math.floor(Number.MAX_SAFE_INTEGER / 100),
      }),
    ).toEqual([]);
  });

  it.each([
    { page: undefined },
    { page: '' },
    { page: '   ' },
    { page: 'nope' },
    { page: -1 },
    { page: 0.5 },
    { page: Number.MAX_SAFE_INTEGER },
    { window: 0 },
    { window: 1.5 },
    { window: Math.floor(Number.MAX_SAFE_INTEGER / 100) + 1 },
    { limit: 0 },
    { limit: 101 },
    { cursor: '1' },
  ])('rejects missing or unsafe window coordinates: %o', async (invalid) => {
    expect((await errorsFor(NativeSourceInkWindowQueryDto, { ...scope, page: 0, ...invalid })).length).toBeGreaterThan(0);
  });
});

function inkRequest() {
  return {
    deviceId: 'ipad',
    operations: [
      {
        operationId: 'e3bd84ba-1995-4ccb-bf59-79c16c93ee52',
        clientId: 'b9061969-d213-4b90-a7e6-bf71f7b7fc43',
        bookId: 5,
        baseVersion: 0,
        action: 'create',
        payload: {
          kind: 'pdf_ink',
          bookFileId: 12,
          sourceRevision: 'revision-1',
          pageFingerprint: 'fingerprint-3',
          pdf: { page: 0, rect: { x: 1, y: 2, width: 3, height: 4 }, rects: [] },
          drawing: {
            format: 'bookorbit-ink-v1',
            nativeData: 'native-pencilkit-data',
            strokes: [{ id: 'stroke-1', color: '#123456', width: 2, points: [{ x: 1, y: 2, pressure: 0.5 }] }],
          },
        },
      },
    ],
  };
}

describe('Source ink operation body validation', () => {
  it('preserves valid nested source-native ink and PDF anchor fields under the global whitelist', async () => {
    const request = inkRequest();
    const dto = plainToInstance(NativeAnnotationOperationsDto, request);
    expect(await validate(dto, { whitelist: true, forbidNonWhitelisted: true })).toEqual([]);
    expect(dto.operations[0].payload).toEqual(request.operations[0].payload);
  });

  it.each([
    ['point', { x: '1', y: 2 }],
    ['point', { x: 1, y: 2, pressure: 1.1 }],
    ['point', { x: 1, y: 2, hidden: true }],
    ['stroke', { id: '' }],
    ['stroke', { color: 'red' }],
    ['stroke', { width: 0 }],
    ['stroke', { points: [null] }],
    ['operation', { clientId: 'not-a-uuid' }],
    ['operation', { baseVersion: -1 }],
    ['pdf', { page: -1 }],
    ['pdf', { rect: { x: 1, y: 2, width: 0, height: 4 } }],
  ] as const)('rejects malformed nested %s fields: %o', async (target, invalid) => {
    const request = inkRequest();
    const operation = request.operations[0];
    if (target === 'point') Object.assign(operation.payload.drawing.strokes[0].points[0], invalid);
    if (target === 'stroke') Object.assign(operation.payload.drawing.strokes[0], invalid);
    if (target === 'operation') Object.assign(operation, invalid);
    if (target === 'pdf') Object.assign(operation.payload.pdf, invalid);
    expect((await errorsFor(NativeAnnotationOperationsDto, request)).length).toBeGreaterThan(0);
  });
});
