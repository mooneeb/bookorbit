import { ValidationPipe } from '@nestjs/common';
import { NativeAnnotationHubDevicesQueryDto, NativeAnnotationHubExportQueryDto, NativeAnnotationHubQueryDto } from './native-annotation-hub.dto';
const pipe = new ValidationPipe({ whitelist: true, forbidNonWhitelisted: true, transform: true });
function parse(metatype: typeof NativeAnnotationHubQueryDto | typeof NativeAnnotationHubDevicesQueryDto, value: object) {
  return pipe.transform(value, { type: 'query', metatype });
}
describe('Native annotation hub query validation', () => {
  it('transforms query strings and trims search while retaining all supported filters', async () => {
    expect(
      await parse(NativeAnnotationHubQueryDto, {
        cursor: '9',
        limit: '100',
        bookId: '4',
        fileId: '5',
        search: '  ink  ',
        kind: 'pdf_ink',
        status: 'recovery',
        groupBy: 'source',
      }),
    ).toEqual({ cursor: 9, limit: 100, bookId: 4, fileId: 5, search: 'ink', kind: 'pdf_ink', status: 'recovery', groupBy: 'source' });
  });
  it('accepts empty optional queries and every documented grouping', async () => {
    expect(await parse(NativeAnnotationHubQueryDto, {})).toEqual({});
    for (const groupBy of ['book', 'month', 'kind', 'source']) expect(await parse(NativeAnnotationHubQueryDto, { groupBy })).toEqual({ groupBy });
  });
  it.each([
    { limit: '101' },
    { limit: '0' },
    { cursor: '-1' },
    { bookId: '1.5' },
    { fileId: '0' },
    { search: 3 },
    { search: 'x'.repeat(201) },
    { status: 'deleted' },
    { kind: 'unknown' },
    { groupBy: 'user' },
    { userId: '8' },
  ])('rejects invalid or unscoped query %j', async (query) => {
    await expect(parse(NativeAnnotationHubQueryDto, query)).rejects.toMatchObject({ status: 400 });
  });
  it('transforms comma-separated export IDs and accepts already numeric arrays', async () => {
    expect(await parse(NativeAnnotationHubExportQueryDto, { ids: '9,10', search: ' book ', limit: '2' })).toEqual({
      ids: [9, 10],
      search: 'book',
      limit: 2,
    });
    expect(await parse(NativeAnnotationHubExportQueryDto, { ids: [9, 10] })).toEqual({ ids: [9, 10] });
  });
  it.each(['', '0,1', '1.5', 'abc', [1, '2'], Array.from({ length: 101 }, (_, index) => index + 1)].map((ids) => ({ ids })))(
    'rejects invalid export selection %j',
    async ({ ids }) => {
      await expect(parse(NativeAnnotationHubExportQueryDto, { ids })).rejects.toMatchObject({ status: 400 });
    },
  );
  it('transforms device book and limit without changing its opaque cursor', async () => {
    expect(await parse(NativeAnnotationHubDevicesQueryDto, { limit: '10', bookId: '4', cursor: 'opaque-cursor' })).toEqual({
      limit: 10,
      bookId: 4,
      cursor: 'opaque-cursor',
    });
  });
  it.each([{ limit: '101' }, { bookId: '0' }, { cursor: 'x'.repeat(513) }, { cursor: 12 }, { userId: 8 }])(
    'rejects invalid device query %j',
    async (query) => {
      await expect(parse(NativeAnnotationHubDevicesQueryDto, query)).rejects.toMatchObject({ status: 400 });
    },
  );
});
