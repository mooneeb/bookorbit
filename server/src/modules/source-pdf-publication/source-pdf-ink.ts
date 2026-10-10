import { BadRequestException, ConflictException, ForbiddenException } from '@nestjs/common';
import { createHash } from 'crypto';
import { PDFArray, PDFDict, PDFDocument, PDFHexString, PDFName, PDFNumber, PDFPage, PDFRawStream } from 'pdf-lib';

import type { NativeAnnotationDrawing } from '@bookorbit/types';

export interface SourcePdfInkChange {
  annotationId: number;
  creatorUserId: number;
  version: number;
  operationId: string;
  deleted: boolean;
  drawing: NativeAnnotationDrawing | null;
  page: number;
  pageFingerprint?: string | null;
  sourceRevision?: string | null;
}

interface IndexedInk {
  annotations: PDFArray;
  annotation: PDFDict;
}
const inkIndexes = new WeakMap<PDFDocument, Map<number, IndexedInk[]>>();

function sourceInkIndex(document: PDFDocument): Map<number, IndexedInk[]> {
  const existing = inkIndexes.get(document);
  if (existing) return existing;
  const index = new Map<number, IndexedInk[]>();
  for (const page of document.getPages()) {
    const annotations = page.node.Annots();
    if (!annotations) continue;
    for (const reference of annotations.asArray()) {
      const annotation = document.context.lookup(reference);
      if (!(annotation instanceof PDFDict)) continue;
      const id = annotation.lookupMaybe(PDFName.of('BookOrbitAnnotationId'), PDFNumber)?.asNumber();
      if (id == null) continue;
      const group = index.get(id) ?? [];
      group.push({ annotations, annotation });
      index.set(id, group);
    }
  }
  inkIndexes.set(document, index);
  return index;
}

export function sourcePdfRevision(bytes: Uint8Array): string {
  return `sha256:${createHash('sha256').update(bytes).digest('hex')}`;
}

export function sourcePdfPageFingerprint(document: PDFDocument, page: PDFPage): string {
  const hash = createHash('sha256').update(JSON.stringify([page.getMediaBox(), page.getCropBox(), page.getRotation().angle]));
  const visited = new Set<string>();
  const include = (value: unknown): void => {
    if (value == null) return;
    const object = document.context.lookup(value as Parameters<typeof document.context.lookup>[0]);
    if (!object) return;
    const reference = document.context.getObjectRef(object)?.toString();
    if (reference && visited.has(reference)) return;
    if (reference) visited.add(reference);
    if (object instanceof PDFRawStream) {
      hash.update(object.contents);
      for (const [key, child] of object.dict.entries()) if (!['Length', 'Filter', 'DecodeParms'].includes(key.decodeText())) include(child);
    } else if (object instanceof PDFArray) {
      for (const child of object.asArray()) include(child);
    } else if (object instanceof PDFDict) {
      for (const [key, child] of object.entries()) {
        if (key.decodeText() === 'Parent') continue;
        hash.update(key.decodeText());
        include(child);
      }
    } else hash.update(object.toString());
  };
  include(page.node.Contents());
  include(page.node.Resources());
  return hash.digest('hex');
}

export function assertWritableSourcePdf(document: PDFDocument): void {
  if (document.isEncrypted) throw new ForbiddenException('Encrypted PDF content cannot be changed');
  if (document.catalog.has(PDFName.of('Perms'))) throw new ForbiddenException('Certified PDF content cannot be changed');
  for (const [, object] of document.context.enumerateIndirectObjects()) {
    if (!(object instanceof PDFDict)) continue;
    if (object.get(PDFName.of('Type'))?.toString() === '/Sig' || object.get(PDFName.of('FT'))?.toString() === '/Sig') {
      throw new ForbiddenException('Signed PDF content cannot be changed');
    }
  }
}

export function sourcePdfInkVersion(document: PDFDocument, annotationId: number): number {
  return (
    document.catalog
      .lookupMaybe(PDFName.of('BookOrbitInkVersions'), PDFDict)
      ?.lookupMaybe(PDFName.of(String(annotationId)), PDFNumber)
      ?.asNumber() ?? 0
  );
}

export function applySourcePdfInk(document: PDFDocument, change: SourcePdfInkChange): boolean {
  if (!Number.isInteger(change.page) || change.page < 0 || change.page >= document.getPageCount()) {
    throw new ConflictException('The source PDF page no longer exists');
  }
  const page = document.getPage(change.page);
  if (change.pageFingerprint && change.pageFingerprint !== sourcePdfPageFingerprint(document, page)) {
    throw new ConflictException('The source PDF page was replaced; retain this change as a recovery draft');
  }
  const versions = document.catalog.lookupMaybe(PDFName.of('BookOrbitInkVersions'), PDFDict) ?? document.context.obj({});
  const versionKey = PDFName.of(String(change.annotationId));
  const publishedVersion = sourcePdfInkVersion(document, change.annotationId);
  if (publishedVersion >= change.version) return false;
  const inkIndex = sourceInkIndex(document);
  const matching = inkIndex.get(change.annotationId) ?? [];
  for (const { annotation } of matching) {
    const owner = annotation.lookupMaybe(PDFName.of('BookOrbitUserId'), PDFNumber)?.asNumber();
    if (owner !== change.creatorUserId) throw new ForbiddenException('Source ink creator does not match the canonical item');
    const flags = annotation.lookupMaybe(PDFName.of('F'), PDFNumber)?.asNumber() ?? 0;
    if (flags & (64 | 128 | 512)) throw new ForbiddenException('Protected source ink cannot be changed');
  }
  if (!change.deleted) validateDrawing(change.drawing, page);
  for (const { annotations, annotation } of matching) {
    const index = annotations.asArray().findIndex((reference) => document.context.lookup(reference) === annotation);
    if (index >= 0) annotations.remove(index);
  }
  if (!change.deleted) inkIndex.set(change.annotationId, [appendInk(document, page, change)]);
  else inkIndex.delete(change.annotationId);
  versions.set(versionKey, PDFNumber.of(change.version));
  document.catalog.set(PDFName.of('BookOrbitInkVersions'), versions);
  return true;
}

function geometry(page: PDFPage): { width: number; height: number; toPdf: (x: number, y: number) => [number, number] } {
  const box = page.getCropBox();
  const rotation = ((page.getRotation().angle % 360) + 360) % 360;
  if (![0, 90, 180, 270].includes(rotation)) throw new BadRequestException('Unsupported PDF page rotation');
  return {
    width: rotation % 180 ? box.height : box.width,
    height: rotation % 180 ? box.width : box.height,
    toPdf: (x, y) => {
      if (rotation === 90) return [box.x + y, box.y + x];
      if (rotation === 180) return [box.x + box.width - x, box.y + y];
      if (rotation === 270) return [box.x + box.width - y, box.y + box.height - x];
      return [box.x + x, box.y + box.height - y];
    },
  };
}

export function sourcePdfPageSize(page: PDFPage): { width: number; height: number } {
  const { width, height } = geometry(page);
  return { width, height };
}

function validateDrawing(drawing: NativeAnnotationDrawing | null, page: PDFPage): asserts drawing is NativeAnnotationDrawing {
  if (
    !drawing ||
    drawing.format !== 'bookorbit-ink-v1' ||
    !Array.isArray(drawing.strokes) ||
    !drawing.strokes.length ||
    drawing.strokes.length > 1000
  ) {
    throw new BadRequestException('Source ink requires a retained drawing with 1 to 1000 strokes');
  }
  const { width, height } = geometry(page);
  let pointCount = 0;
  for (const stroke of drawing.strokes) {
    if (!/^#[0-9a-f]{6}$/i.test(stroke.color) || !Number.isFinite(stroke.width) || stroke.width <= 0 || stroke.width > 100) {
      throw new BadRequestException('Invalid source ink color or width');
    }
    if (!Array.isArray(stroke.points) || stroke.points.length < 1) throw new BadRequestException('Source ink strokes require points');
    pointCount += stroke.points.length;
    if (pointCount > 100_000) throw new BadRequestException('Source ink exceeds the point limit');
    for (const point of stroke.points) {
      if (!Number.isFinite(point.x) || !Number.isFinite(point.y) || point.x < 0 || point.y < 0 || point.x > width || point.y > height) {
        throw new BadRequestException('Source ink points must fit the PDF page');
      }
    }
  }
  if (Buffer.byteLength(JSON.stringify(drawing)) > 8 * 1024 * 1024) throw new BadRequestException('Source ink exceeds the retained drawing limit');
}

function appendInk(document: PDFDocument, page: PDFPage, change: SourcePdfInkChange): IndexedInk {
  const drawing = change.drawing!;
  const { toPdf } = geometry(page);
  const inkLists = drawing.strokes.map((stroke) => stroke.points.flatMap((point) => toPdf(point.x, point.y)));
  let minX = Infinity;
  let minY = Infinity;
  let maxX = -Infinity;
  let maxY = -Infinity;
  for (const [index, coordinates] of inkLists.entries()) {
    const radius = drawing.strokes[index].width / 2;
    for (let point = 0; point < coordinates.length; point += 2) {
      minX = Math.min(minX, coordinates[point] - radius);
      minY = Math.min(minY, coordinates[point + 1] - radius);
      maxX = Math.max(maxX, coordinates[point] + radius);
      maxY = Math.max(maxY, coordinates[point + 1] + radius);
    }
  }
  const number = (value: number) => Number(value.toFixed(4));
  const appearance = ['q', '1 J', '1 j'];
  for (const [index, stroke] of drawing.strokes.entries()) {
    const color = [1, 3, 5].map((offset) => number(parseInt(stroke.color.slice(offset, offset + 2), 16) / 255));
    appearance.push(`${color.join(' ')} RG`, `${number(stroke.width)} w`);
    const coordinates = inkLists[index];
    appearance.push(`${number(coordinates[0] - minX)} ${number(coordinates[1] - minY)} m`);
    if (coordinates.length === 2) appearance.push(`${number(coordinates[0] - minX + 0.001)} ${number(coordinates[1] - minY)} l`);
    for (let point = 2; point < coordinates.length; point += 2)
      appearance.push(`${number(coordinates[point] - minX)} ${number(coordinates[point + 1] - minY)} l`);
    appearance.push('S');
  }
  appearance.push('Q');
  const stream = document.context.flateStream(appearance.join('\n'), {
    Type: 'XObject',
    Subtype: 'Form',
    FormType: 1,
    BBox: [0, 0, maxX - minX, maxY - minY],
    Resources: {},
  });
  const annotation = document.context.obj({
    Type: 'Annot',
    Subtype: 'Ink',
    P: page.ref,
    Rect: [minX, minY, maxX, maxY],
    NM: PDFHexString.fromText(`bookorbit:${change.annotationId}`),
    F: 4,
    InkList: inkLists,
    BS: { W: drawing.strokes[0].width, S: 'S' },
    AP: { N: document.context.register(stream) },
    BookOrbitAnnotationId: change.annotationId,
    BookOrbitUserId: change.creatorUserId,
    BookOrbitVersion: change.version,
    BookOrbitDrawing: PDFHexString.fromText(JSON.stringify(drawing)),
    BookOrbitOperationId: PDFHexString.fromText(change.operationId),
  });
  const annotations = page.node.Annots() ?? document.context.obj([]);
  annotations.push(document.context.register(annotation));
  page.node.set(PDFName.of('Annots'), annotations);
  return { annotations, annotation };
}
