import { BadRequestException } from '@nestjs/common';
import { readFile } from 'node:fs/promises';
import { join } from 'node:path';
import { XMLParser, XMLValidator } from 'fast-xml-parser';
import { load } from 'cheerio';
import type { NativeEpubSession } from '@bookorbit/types';

export async function validateOfflineEpub(directory: string, members: NativeEpubSession['members']): Promise<void> {
  const index = new Map(members.map((member, id) => [member.path, { ...member, id }]));
  const read = async (path: string) => {
    const member = index.get(path);
    if (!member) throw new BadRequestException('EPUB required member is missing');
    if (member.bytes > 4 * 1024 * 1024) throw new BadRequestException('EPUB text resource exceeds 4 MiB');
    return readFile(join(directory, String(member.id)), 'utf8');
  };
  const xml = (text: string) => {
    if (/<!DOCTYPE|<!ENTITY/i.test(text) || XMLValidator.validate(text) !== true) throw new BadRequestException('Invalid EPUB package XML');
    return new XMLParser({
      ignoreAttributes: false,
      removeNSPrefix: true,
      processEntities: false,
      isArray: (name) => ['rootfile', 'item', 'itemref'].includes(name),
    }).parse(text);
  };
  const resolve = (value: string, base: string): string | null => {
    let url: URL;
    try {
      url = new URL(value, `https://publication.invalid/${base}`);
    } catch {
      throw new BadRequestException('Invalid EPUB resource reference');
    }
    if (url.origin !== 'https://publication.invalid') return null;
    let path: string;
    try {
      path = decodeURIComponent(url.pathname.slice(1));
    } catch {
      throw new BadRequestException('Invalid EPUB resource encoding');
    }
    if (!index.has(path)) throw new BadRequestException('EPUB required member is missing');
    return path;
  };
  const container = xml(await read('META-INF/container.xml'));
  const packagePath = container.container?.rootfiles?.rootfile?.find(
    (root: Record<string, string>) => root['@_media-type'] === 'application/oebps-package+xml',
  )?.['@_full-path'];
  if (typeof packagePath !== 'string' || !index.has(packagePath)) throw new BadRequestException('EPUB package document is missing');
  const packageDocument = xml(await read(packagePath)).package;
  const items = packageDocument?.manifest?.item;
  const spine = packageDocument?.spine?.itemref;
  if (!Array.isArray(items) || !Array.isArray(spine) || !spine.length) throw new BadRequestException('EPUB manifest or spine is missing');
  const ids = new Map<string, Record<string, string>>();
  for (const item of items) {
    if (typeof item['@_id'] !== 'string' || ids.has(item['@_id']) || typeof item['@_href'] !== 'string')
      throw new BadRequestException('Ambiguous EPUB manifest');
    ids.set(item['@_id'], item);
    const path = resolve(item['@_href'], packagePath);
    if (path === null) continue;
    const type = item['@_media-type'];
    if (['application/xhtml+xml', 'text/html', 'image/svg+xml', 'text/css'].includes(type)) {
      const text = await read(path);
      if (type === 'text/css') {
        for (const match of text.matchAll(/url\(\s*["']?([^"')]+)["']?\s*\)/gi)) resolve(match[1].trim(), path);
      } else {
        const doc = load(text, { xmlMode: type !== 'text/html' });
        for (const element of doc('[src], link[href], image[href], image[xlink\\:href]').toArray()) {
          const ref = doc(element).attr('src') ?? doc(element).attr('href') ?? doc(element).attr('xlink:href');
          if (ref && !ref.startsWith('#')) resolve(ref, path);
        }
      }
    }
  }
  for (const item of spine) {
    const manifestItem = ids.get(item['@_idref']);
    if (!manifestItem || !['application/xhtml+xml', 'text/html'].includes(manifestItem['@_media-type']))
      throw new BadRequestException('Unsupported EPUB spine');
  }
}
