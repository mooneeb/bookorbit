import "./assets/view.js";
import { EPUB } from "./assets/epub.js";

const session = location.pathname.split("/")[1];
const report = (kind, value = "") => window.webkit.messageHandlers.reader.postMessage({ session, kind, value });
const fail = () =>
  report(
    "error",
    "This publication could not be read safely. A resource may be missing, unsupported, oversized or disconnected. Return to details and retry.",
  );
let retained = 0;
const objectURLs = new Map();
const createObjectURL = URL.createObjectURL.bind(URL);
const revokeObjectURL = URL.revokeObjectURL.bind(URL);
URL.createObjectURL = (blob) => {
  if (retained + blob.size > 128 * 1024 * 1024) return refuse();
  const url = createObjectURL(blob);
  objectURLs.set(url, blob.size);
  retained += blob.size;
  return url;
};
URL.revokeObjectURL = (url) => {
  retained -= objectURLs.get(url) ?? 0;
  objectURLs.delete(url);
  revokeObjectURL(url);
};
let failed = false;
let partial = false;
const refuse = () => {
  failed = true;
  fail();
  throw new Error("Publication unavailable");
};
const manifest = await fetch("manifest.json").then((response) => response.json());
const members = new Map(manifest.members.map((member, index) => [member.path, { ...member, index }]));
const textTypes = /\.(?:xhtml|html?|css|xml|opf|ncx|svg)$/i;
const load = async (name) => {
  if (failed) throw new Error("Reader stopped");
  const member = members.get(name);
  if (!member) {
    if (["META-INF/encryption.xml", "META-INF/com.apple.ibooks.display-options.xml", "META-INF/com.kobobooks.display-options.xml"].includes(name))
      return null;
    return refuse();
  }
  const limit = textTypes.test(name) ? 4 * 1024 * 1024 : 32 * 1024 * 1024;
  if (member.bytes > limit) return refuse();
  const response = await fetch(`member/${member.index}`, { signal: AbortSignal.timeout(10_000) });
  if (!response.ok) return refuse();
  const data = await response.arrayBuffer();
  if (data.byteLength !== member.bytes) return refuse();
  return data;
};

// Each source document carries a restrictive policy before Foliate creates its iframe.
// Keep body nodes intact so this adapter can share canonical locations with the browser.
const contain = (text, name) => {
  const type = /\.html?$/i.test(name) ? "text/html" : "application/xhtml+xml";
  const doc = new DOMParser().parseFromString(text, type);
  if (doc.querySelector("parsererror")) return refuse();
  const walker = doc.createTreeWalker(doc, NodeFilter.SHOW_ALL);
  let count = 0;
  while (walker.nextNode()) if (++count > 100_000) return refuse();
  if (doc.querySelector('meta[http-equiv="refresh" i], iframe, object, embed, video, audio') || /writing-mode\s*:\s*vertical/i.test(text))
    return refuse();
  if (
    doc.querySelector('script, [src^="http:"], [src^="https:"], link[href^="http:"], link[href^="https:"]') ||
    Array.from(doc.querySelectorAll("style, [style], [src], [srcset], [poster], link[href]")).some((element) => {
      const values = element.matches("style") ? [element.textContent] : Array.from(element.attributes, (attribute) => attribute.value);
      return values.some((value) => /(?:^|[\s("',])(?:https?:)?\/\//i.test(value));
    })
  )
    partial = true;
  const head = doc.querySelector("head");
  if (!head) return refuse();
  const policy = doc.createElementNS("http://www.w3.org/1999/xhtml", "meta");
  policy.setAttribute("http-equiv", "Content-Security-Policy");
  policy.setAttribute(
    "content",
    "default-src 'none'; script-src 'none'; connect-src 'none'; img-src blob: data:; style-src 'unsafe-inline' blob:; font-src blob:; object-src 'none'; frame-src 'none'; base-uri 'none'; form-action 'none'",
  );
  head.prepend(policy);
  return new XMLSerializer().serializeToString(doc);
};

try {
  const epub = await new EPUB({
    loadText: async (name) => {
      const data = await load(name);
      if (data === null) return null;
      const text = new TextDecoder("utf-8", { fatal: true }).decode(data);
      if (/\.opf$/i.test(name) && /pre-paginated|fixed-layout/i.test(text)) return refuse();
      return /\.(?:xhtml|html?|svg)$/i.test(name) ? contain(text, name) : text;
    },
    loadBlob: async (name) => {
      const data = await load(name);
      return data === null ? null : new Blob([data]);
    },
    getSize: (name) => members.get(name)?.bytes ?? 0,
    sha1: (data) => crypto.subtle.digest("SHA-1", data),
  }).init();
  if (epub.rendition?.layout === "pre-paginated" || epub.sections.some((section) => section.pageSpread)) refuse();
  const view = document.createElement("foliate-view");
  document.querySelector("main").append(view);
  view.addEventListener("load", (event) => {
    const doc = event.detail.doc;
    if (!doc?.body?.textContent?.trim()) return refuse();
    report("ready", partial ? "Partial reading: publication scripts and remote content are unavailable." : "");
  });
  await view.open(epub);
  view.renderer.setAttribute("flow", "paginated");
  await view.init({ showTextStart: true });
  window.readerTurn = async (direction) => {
    if (failed) return;
    try {
      await view[direction]();
      report("location", "EPUB page changed");
    } catch {
      refuse();
    }
  };
} catch {
  failed = true;
  fail();
}
window.addEventListener("unhandledrejection", () => {
  failed = true;
  fail();
});
