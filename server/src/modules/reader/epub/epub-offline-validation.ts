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
    if (url.protocol === 'data:') throw new BadRequestException('Embedded data resources are unsupported; use archive image and font members');
    if (url.origin !== 'https://publication.invalid') return null;
    let path: string;
    try {
      path = decodeURIComponent(url.pathname.slice(1));
    } catch {
      throw new BadRequestException('Invalid EPUB resource encoding');
    }
    if (!index.has(path)) throw new BadRequestException(`EPUB required member is missing: ${path}`);
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
  const declared = new Map<string, string>();
  for (const item of items) {
    if (typeof item['@_id'] !== 'string' || ids.has(item['@_id']) || typeof item['@_href'] !== 'string')
      throw new BadRequestException('Ambiguous EPUB manifest');
    ids.set(item['@_id'], item);
    const path = resolve(item['@_href'], packagePath);
    if (path === null) continue;
    declared.set(path, item['@_media-type']);
  }
  const resource = (value: string, base: string) => {
    const path = resolve(value, base);
    if (path !== null && !declared.has(path)) throw new BadRequestException('EPUB required resource is not declared in its manifest');
  };
  const css = (text: string, path: string) => {
    if (/writing-mode\s*:\s*vertical/i.test(text)) throw new BadRequestException('EPUB vertical writing is unsupported');
    for (const match of text.matchAll(/url\(\s*["']?([^'"\n]*?)\s*["']?\s*\)/gi)) resource(match[1], path);
    for (const match of text.matchAll(/@import\s*["']([^"'\n]*?)["']/gi)) resource(match[1], path);
  };
  for (const [path, type] of declared) {
    if (['application/xhtml+xml', 'text/html', 'image/svg+xml', 'text/css'].includes(type)) {
      const text = await read(path);
      let tags = 0;
      for (const character of text) if (character === '<' && ++tags > 100_000) throw new BadRequestException('EPUB section exceeds the node limit');
      if (type === 'text/css') {
        css(text, path);
      } else {
        const doc = load(text, { xmlMode: type !== 'text/html' });
        if (doc('meta[http-equiv="refresh" i], iframe, object, embed, video, audio').length)
          throw new BadRequestException('EPUB interactive media is unsupported');
        const pending = [...(doc.root().get(0)?.children ?? [])];
        let nodes = 0;
        while (pending.length) {
          const node = pending.pop();
          if (!node) break;
          if (++nodes > 100_000) throw new BadRequestException('EPUB section exceeds the node limit');
          if ('children' in node) for (const child of node.children) pending.push(child);
        }
        for (const element of doc('[src], link[href], image[href], image[xlink\\:href], use[href], use[xlink\\:href]').toArray()) {
          const ref = doc(element).attr('src') ?? doc(element).attr('href') ?? doc(element).attr('xlink:href');
          if (ref && !ref.startsWith('#')) resource(ref, path);
        }
        for (const element of doc('[srcset]').toArray()) {
          for (const match of (doc(element).attr('srcset') ?? '').matchAll(/(\s*)(.+?)\s*((?:\s[\d.]+[wx])+\s*(?:,|$)|,\s+|$)/g))
            resource(match[2], path);
        }
        for (const element of doc('style').toArray()) css(doc(element).text(), path);
        for (const element of doc('[style]').toArray()) css(doc(element).attr('style') ?? '', path);
      }
    }
  }
  for (const item of spine) {
    const manifestItem = ids.get(item['@_idref']);
    if (!manifestItem || !['application/xhtml+xml', 'text/html'].includes(manifestItem['@_media-type']))
      throw new BadRequestException('Unsupported EPUB spine');
  }
  const rawMetadata = packageDocument.metadata?.meta;
  const metadata = Array.isArray(rawMetadata) ? rawMetadata : rawMetadata ? [rawMetadata] : [];
  const defaultFixed = metadata.some(
    (meta: Record<string, string>) =>
      (meta['@_property'] === 'rendition:layout' && String(meta['#text']).trim() === 'pre-paginated') ||
      (meta['@_name'] === 'fixed-layout' && /^(?:true|yes)$/i.test(meta['@_content'] ?? '')),
  );
  const layouts = new Set(
    spine.map((item: Record<string, string>) => {
      const properties = item['@_properties'] ?? '';
      return properties.includes('rendition:layout-pre-paginated')
        ? 'fixed'
        : properties.includes('rendition:layout-reflowable')
          ? 'reflow'
          : defaultFixed
            ? 'fixed'
            : 'reflow';
    }),
  );
  if (layouts.size !== 1) throw new BadRequestException('EPUB mixed spine layouts are unsupported');
}
