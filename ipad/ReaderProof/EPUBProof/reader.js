import "../foliate/view.js";
import { EPUB } from "../foliate/epub.js";

const view = document.querySelector("foliate-view");
const resource = (path) => window.webkit.messageHandlers.resource.postMessage(path);

window.openPublication = async (info, cfi) => {
  const manifest = new Map(info.manifest.map((item) => [item.href, item]));
  const paths = new Set(["META-INF/container.xml", info.containerPath, ...(info.optionalFiles ?? []), ...manifest.keys()]);
  const bytes = async (path) => {
    if (!paths.has(path)) return null;
    const encoded = await resource(path);
    return Uint8Array.from(atob(encoded), (value) => value.charCodeAt(0));
  };
  const book = await new EPUB({
    loadText: async (path) => {
      const data = await bytes(path);
      return data ? new TextDecoder("utf-8", { fatal: true }).decode(data) : null;
    },
    loadBlob: async (path, type) => {
      const data = await bytes(path);
      return data ? new Blob([data], { type: type ?? manifest.get(path)?.mediaType }) : null;
    },
    getSize: (path) => manifest.get(path)?.size ?? 0,
  }).init();
  book.transformTarget.addEventListener("data", (event) => {
    if (!["application/xhtml+xml", "text/html"].includes(event.detail.type)) return;
    event.detail.data = Promise.resolve(event.detail.data).then((text) => {
      const doc = new DOMParser().parseFromString(text, event.detail.type);
      const policy = doc.createElementNS("http://www.w3.org/1999/xhtml", "meta");
      policy.setAttribute("http-equiv", "Content-Security-Policy");
      policy.setAttribute("content", "script-src 'none'; connect-src 'none'; object-src 'none'; frame-src 'none'");
      doc.querySelector("head")?.prepend(policy);
      return new XMLSerializer().serializeToString(doc);
    });
  });
  await view.open(book);
  view.renderer.disablePointerNavigation?.();
  view.renderer.setStyles("::highlight(selected-passage) { background-color: Highlight; color: HighlightText; }");
  view.renderer.setAttribute("max-column-count", "1");
  await view.goTo(cfi || 0);
  await view.renderer.getContents()[0].doc.fonts.ready;
};

window.resolvePassage = async (cfi) => {
  const destination = view.resolveCFI(cfi);
  await view.goTo(cfi);
  const content = view.renderer.getContents().find((item) => item.index === destination.index);
  if (!content) throw new Error("The passage's chapter could not be opened.");
  await content.doc.fonts.ready;
  const range = destination.anchor(content.doc);
  if (!range || range.collapsed) throw new Error("Enter a passage range anchor.");
  const selection = content.doc.defaultView.getSelection();
  view.renderer.focusView();
  selection.removeAllRanges();
  selection.addRange(range);
  content.doc.defaultView.CSS.highlights.set("selected-passage", new content.doc.defaultView.Highlight(range));
  await new Promise((resolve) => content.doc.defaultView.requestAnimationFrame(resolve));
  const fraction = view.lastLocation?.fraction;
  if (!Number.isFinite(fraction) || fraction < 0 || fraction > 1) throw new Error("The passage position is unavailable.");
  return { text: selection.toString(), cfi: view.getCFI(destination.index, range), percentage: fraction * 100 };
};

window.openPlainChapter = async () => {
  const source = await view.book.sections[0].load();
  const frame = document.createElement("iframe");
  frame.className = "plain-chapter";
  frame.title = "Delivered EPUB chapter";
  frame.sandbox = "allow-same-origin";
  frame.referrerPolicy = "no-referrer";
  const loaded = new Promise((resolve) => frame.addEventListener("load", resolve, { once: true }));
  frame.src = source;
  document.body.replaceChildren(frame);
  await loaded;
  await frame.contentDocument.fonts.ready;
  await new Promise((resolve) => frame.contentWindow.requestAnimationFrame(resolve));
};
