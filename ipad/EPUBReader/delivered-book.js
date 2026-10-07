import { MOBI, isMOBI } from "../foliate/mobi.js";
import { makeFB2 } from "../foliate/fb2.js";

const maximumTextBytes = 32 * 1024 * 1024;
const maximumResourceBytes = 8 * 1024 * 1024;
const boundedUnzlib = async (bytes) => {
  if (!bytes.length) throw new Error("The compressed font is unavailable.");
  const chunks = [];
  let length = 0;
  const reader = new Blob([bytes]).stream().pipeThrough(new DecompressionStream("deflate")).getReader();
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      length += value.length;
      if (length > maximumResourceBytes) throw new Error("The decoded font exceeds the resource limit.");
      chunks.push(value);
    }
  } finally {
    await reader.cancel().catch(() => {});
    reader.releaseLock();
  }
  const result = new Uint8Array(length);
  let offset = 0;
  for (const chunk of chunks) {
    result.set(chunk, offset);
    offset += chunk.length;
  }
  return result;
};
const publicationPolicy =
  "default-src 'none'; script-src 'none'; connect-src 'none'; object-src 'none'; frame-src 'none'; media-src 'none'; style-src 'unsafe-inline' blob:; img-src blob: data:; font-src blob: data:";
const protectDocument = (doc) => {
  for (const element of doc.querySelectorAll("script")) element.setAttribute("type", "application/x-bookorbit-disabled");
  for (const element of doc.querySelectorAll("*")) {
    for (const attribute of Array.from(element.attributes)) {
      if (attribute.name.toLowerCase().startsWith("on")) element.removeAttributeNode(attribute);
    }
  }
  const policy = doc.createElementNS("http://www.w3.org/1999/xhtml", "meta");
  policy.setAttribute("http-equiv", "Content-Security-Policy");
  policy.setAttribute("content", publicationPolicy);
  doc.querySelector("head")?.prepend(policy);
  return doc;
};
const decodeXML = (bytes) => {
  const prefix = new TextDecoder().decode(bytes.subarray(0, 512));
  const encoding =
    bytes[0] === 0xff && bytes[1] === 0xfe
      ? "utf-16le"
      : bytes[0] === 0xfe && bytes[1] === 0xff
        ? "utf-16be"
        : bytes[0] === 0 && bytes[1] === 0x3c
          ? "utf-16be"
          : bytes[0] === 0x3c && bytes[1] === 0
            ? "utf-16le"
            : (prefix.match(/<\?xml[^>]*encoding\s*=\s*["']([^"']+)["']/i)?.[1] ?? "utf-8");
  return new TextDecoder(encoding, { fatal: true }).decode(bytes);
};
const virtualFile = (size, format, read) => {
  const slice = (start = 0, end = size) => {
    const offset = start < 0 ? Math.max(0, size + start) : Math.min(start, size);
    const stop = end < 0 ? Math.max(0, size + end) : Math.min(end, size);
    return {
      arrayBuffer: async () => {
        const length = Math.max(0, stop - offset);
        if (!Number.isSafeInteger(offset) || !Number.isSafeInteger(length) || length > maximumResourceBytes)
          throw new Error("The ebook record exceeds the resource limit.");
        return (await read(offset, length)).buffer;
      },
    };
  };
  return { size, name: `publication.${format}`, slice };
};
const boundedOutline = (book) => {
  if (!Array.isArray(book.sections) || !book.sections.length || book.sections.length > 4096) throw new Error("The book exceeds the section limit.");
  let entries = 0;
  const map = (items, depth = 0) => {
    if (!Array.isArray(items)) return [];
    if (depth > 32 || items.length + entries > 4096) throw new Error("The contents exceed the outline limit.");
    return items.map((item) => {
      if (entries >= 4096) throw new Error("The contents exceed the outline limit.");
      entries++;
      const href = typeof item.href === "string" ? item.href : null;
      if (href?.length > 4096) throw new Error("A contents address exceeds the navigation limit.");
      return { label: String(item.label ?? "").slice(0, 500), href, children: map(item.subitems ?? item.children, depth + 1) };
    });
  };
  return { sectionCount: book.sections.length, toc: map(book.toc) };
};
export const makeDeliveredBook = async (format, size, read) => {
  if (!["mobi", "azw3", "azw", "fb2"].includes(format) || !Number.isSafeInteger(size) || size < 1 || size > 64 * 1024 * 1024)
    throw new Error("The delivered ebook is unavailable.");
  const ownedURLs = new Set();
  let book;
  try {
    if (format === "fb2") {
      if (size > maximumTextBytes) throw new Error("The FictionBook exceeds the XML limit.");
      const xml = decodeXML(await read(0, size)).replace(/^\s*<\?xml[^>]*\?>/i, "");
      const images = new Map();
      let imageBytes = 0;
      book = await makeFB2(new Blob([xml], { type: "application/xml" }), {
        maximumSections: 4096,
        maximumTextBytes,
        trackURL: (url) => ownedURLs.add(url),
        imageURL: (id, type, encoded) => {
          if (images.has(id)) return images.get(id);
          const compact = encoded.replace(/\s+/g, "");
          if (compact.length > Math.ceil(maximumResourceBytes / 3) * 4) throw new Error("An embedded image exceeds the resource limit.");
          const bytes = Uint8Array.from(atob(compact), (character) => character.charCodeAt(0));
          imageBytes += bytes.length;
          if (bytes.length > maximumResourceBytes || imageBytes > maximumTextBytes) throw new Error("The book exceeds the embedded resource limit.");
          const url = URL.createObjectURL(new Blob([bytes], { type }));
          ownedURLs.add(url);
          images.set(id, url);
          return url;
        },
      });
      book.destroy();
      for (const section of book.sections) {
        const createDocument = section.createDocument;
        section.createDocument = async () => protectDocument(await createDocument());
        let current;
        section.load = async () => {
          if (!current) {
            const doc = await section.createDocument();
            current = URL.createObjectURL(new Blob([new XMLSerializer().serializeToString(doc)], { type: "application/xhtml+xml" }));
            ownedURLs.add(current);
          }
          return current;
        };
        section.unload = () => {
          if (current) {
            URL.revokeObjectURL(current);
            ownedURLs.delete(current);
            current = null;
          }
        };
      }
    } else {
      const file = virtualFile(size, format, read);
      if (!(await isMOBI(file))) throw new Error("This file is not a supported MOBI or Kindle publication.");
      const mobi = new MOBI({ unzlib: boundedUnzlib, maximumTextBytes, maximumRecordBytes: maximumResourceBytes });
      const originalText = mobi.loadText.bind(mobi);
      const originalResource = mobi.loadResource.bind(mobi);
      const seenText = new Set();
      const seenResources = new Set();
      let textBytes = 0;
      let resourceBytes = 0;
      mobi.loadText = async (index) => {
        const bytes = await originalText(index);
        if (!seenText.has(index)) {
          seenText.add(index);
          textBytes += bytes.byteLength;
        }
        if (bytes.byteLength > maximumResourceBytes || textBytes > maximumTextBytes) throw new Error("The decoded book exceeds the text limit.");
        return bytes;
      };
      mobi.loadResource = async (index) => {
        const bytes = await originalResource(index);
        if (!seenResources.has(index)) {
          seenResources.add(index);
          resourceBytes += bytes.byteLength;
        }
        if (bytes.byteLength > maximumResourceBytes || resourceBytes > maximumTextBytes)
          throw new Error("The book exceeds the embedded resource limit.");
        return bytes;
      };
      book = await mobi.open(file);
      const parser = book.parser;
      const parse = parser.parseFromString.bind(parser);
      parser.parseFromString = (text, type) => protectDocument(parse(text, type));
    }
    const destroy = book.destroy?.bind(book);
    book.destroy = () => {
      destroy?.();
      for (const url of ownedURLs) URL.revokeObjectURL(url);
      ownedURLs.clear();
    };
    return { book, outline: boundedOutline(book) };
  } catch (error) {
    book?.destroy?.();
    for (const url of ownedURLs) URL.revokeObjectURL(url);
    throw error;
  }
};
