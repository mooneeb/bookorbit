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
const mediaTypes = new Map();
let packagePath;
const textTypes = /\.(?:xhtml|html?|css|xml|opf|ncx|svg)$/i;
const load = async (name, textOnly = false) => {
  if (failed) throw new Error("Reader stopped");
  const member = members.get(name);
  if (!member) {
    if (["META-INF/encryption.xml", "META-INF/com.apple.ibooks.display-options.xml", "META-INF/com.kobobooks.display-options.xml"].includes(name))
      return null;
    return refuse();
  }
  const limit = textOnly || textTypes.test(name) ? 4 * 1024 * 1024 : 32 * 1024 * 1024;
  if (member.bytes > limit) return refuse();
  const response = await fetch(`member/${member.index}`, { signal: AbortSignal.timeout(10_000) });
  if (!response.ok) return refuse();
  const data = await response.arrayBuffer();
  if (data.byteLength !== member.bytes) return refuse();
  return data;
};

// Each source document carries a restrictive policy before Foliate creates its iframe.
// Keep body nodes intact so this adapter can share canonical locations with the browser.
const parseDocument = (text, type) => {
  let tags = 0;
  let offset = 0;
  while ((offset = text.indexOf("<", offset)) !== -1) {
    if (++tags > 100_000) return refuse();
    offset++;
  }
  let doc = new DOMParser().parseFromString(text, type);
  if (doc.querySelector("parsererror") && type === "application/xhtml+xml") doc = new DOMParser().parseFromString(text, "text/html");
  if (doc.querySelector("parsererror")) return refuse();
  return doc;
};
const contain = (text, type) => {
  const doc = parseDocument(text, type);
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
  if (type === "image/svg+xml") {
    for (const element of doc.querySelectorAll("script")) {
      element.remove();
      partial = true;
    }
    for (const element of doc.querySelectorAll("*")) {
      for (const attribute of Array.from(element.attributes)) {
        if (/^on/i.test(attribute.name) || /^\s*javascript:/i.test(attribute.value)) {
          element.removeAttributeNode(attribute);
          partial = true;
        }
      }
    }
    return new XMLSerializer().serializeToString(doc);
  }
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
      const data = await load(name, true);
      if (data === null) return null;
      const text = new TextDecoder("utf-8", { fatal: true }).decode(data);
      if (name === "META-INF/container.xml") {
        const doc = parseDocument(text, "application/xml");
        packagePath = doc.getElementsByTagNameNS("*", "rootfile")[0]?.getAttribute("full-path");
        if (!packagePath || !members.has(packagePath)) return refuse();
      }
      if (name === packagePath) {
        const doc = parseDocument(text, "application/xml");
        if (/pre-paginated|fixed-layout/i.test(text)) return refuse();
        for (const item of doc.getElementsByTagNameNS("*", "item")) {
          const url = new URL(item.getAttribute("href"), "https://publication.invalid/" + packagePath);
          url.search = "";
          url.hash = "";
          if (url.origin !== "https://publication.invalid") return refuse();
          mediaTypes.set(decodeURI(url.pathname.slice(1)), item.getAttribute("media-type"));
        }
      }
      const type = mediaTypes.get(name);
      if (["application/xhtml+xml", "text/html", "image/svg+xml"].includes(type)) return contain(text, type);
      return text;
    },
    loadBlob: async (name) => {
      const data = await load(name);
      return data === null ? null : new Blob([data]);
    },
    getSize: (name) => members.get(name)?.bytes ?? 0,
    sha1: (data) => crypto.subtle.digest("SHA-1", data),
  }).init();
  epub.transformTarget.addEventListener("load", (event) => {
    if (event.detail.isScript) {
      event.detail.allow = false;
      partial = true;
    }
  });
  if (epub.rendition?.layout === "pre-paginated" || epub.sections.some((section) => section.pageSpread)) refuse();
  const view = document.createElement("foliate-view");
  document.querySelector("main").append(view);
  let initialized = false;
  let currentWarning = "";
  view.addEventListener("load", (event) => {
    if (failed) return;
    const doc = event.detail.doc;
    if (!doc?.body) return refuse();
    currentWarning = !doc.body.textContent.trim()
      ? "Text is unavailable in this image-only section."
      : partial
        ? "Partial reading: publication scripts and remote content are unavailable."
        : "";
    if (initialized) report("ready", currentWarning);
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
  initialized = true;
  if (!failed) report("ready", currentWarning);
} catch {
  failed = true;
  fail();
}
window.addEventListener("unhandledrejection", () => {
  failed = true;
  fail();
});
