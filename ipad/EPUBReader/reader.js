import "../foliate/view.js";
import { EPUB } from "../foliate/epub.js";
import { searchMatcher } from "../foliate/search.js";
import { textWalker } from "../foliate/text-walker.js";
import { themes } from "./themes.js";
import { getBlocks } from "../foliate/tts.js";
import { previousSpeechStart } from "./speech-navigation.js";
import { makeDeliveredBook } from "./delivered-book.js";
import { describePosition } from "./position-preview.js";
import { prepareCustomFonts, configureCustomFont, customFontCSS, settleCustomFonts, clearCustomFonts } from "./custom-fonts.js";
import { publicationPosition, fractionTarget, withProgrammaticMovement } from "./position-navigation.js";

const genericFontFamilies = new Set(["serif", "sans-serif", "monospace"]);
const fontFamilyCSS = (family) => (genericFontFamilies.has(family) ? family : JSON.stringify(family));
const view = document.querySelector("foliate-view");
let closed = false;
let narrationMovement = 0;
let recordedSectionLoad;
let active = 0;
let publication;
let publisherSpread;
let currentStyles = "";
let searchState;
let resourceBytes = 0;
let annotationWriting = false;
let passageAnnotations = [];
let pencilMarking = false;
let lastPencilRelease;
const pencilOperationID = () => {
  const bytes = crypto.getRandomValues(new Uint8Array(16));
  bytes[6] = (bytes[6] & 15) | 64;
  bytes[8] = (bytes[8] & 63) | 128;
  const hex = Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("");
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
};
const setPencilMarking = (marking) => {
  pencilMarking = marking;
  view.renderer.style.touchAction = marking ? "none" : "";
  window.webkit.messageHandlers.pencilMarking.postMessage(marking);
};
const matchedPassageAnnotation = (doc, index, selectedRange) => {
  const matches = [];
  for (const item of passageAnnotations) {
    try {
      const resolved = view.resolveNavigation(item.cfi);
      if (resolved?.index !== index) continue;
      const range = resolved.anchor(doc);
      const overlaps = selectedRange.collapsed
        ? range.isPointInRange(selectedRange.startContainer, selectedRange.startOffset)
        : range.comparePoint(selectedRange.startContainer, selectedRange.startOffset) <= 0 &&
          range.comparePoint(selectedRange.endContainer, selectedRange.endOffset) >= 0;
      if (overlaps) matches.push(item);
    } catch {}
  }
  return matches.find((item) => item.kind === "handwriting") ?? matches.find((item) => item.kind === "text_note") ?? matches[0];
};
const releasePencilPassage = (doc, index, operationId) => {
  const passage = selection(doc, index);
  setPencilMarking(false);
  if (!passage) return;
  lastPencilRelease = { ...passage, operationId };
  window.webkit.messageHandlers.selection.postMessage(passage);
  window.webkit.messageHandlers.pencilRelease.postMessage(lastPencilRelease);
  const item = matchedPassageAnnotation(doc, index, doc.getSelection().getRangeAt(0));
  if (item?.kind === "handwriting") window.webkit.messageHandlers.passageAnnotation.postMessage(item.id);
};
const renderPassageAnnotations = (doc, index) => {
  const ranges = [];
  for (const item of passageAnnotations) {
    try {
      const resolved = view.resolveNavigation(item.cfi);
      if (resolved?.index !== index) continue;
      const range = resolved.anchor(doc);
      if (range && !range.collapsed) ranges.push(range);
    } catch {}
  }
  if (doc.defaultView.CSS.highlights && doc.defaultView.Highlight) {
    doc.defaultView.CSS.highlights.set("bookorbit-annotations", new doc.defaultView.Highlight(...ranges));
  }
};
window.epubSetPassageAnnotations = (items) => {
  passageAnnotations = items;
  for (const { doc, index } of view.renderer.getContents()) renderPassageAnnotations(doc, index);
};
window.epubAnnotationWriting = (enabled) => {
  annotationWriting = enabled;
  if (!enabled) setPencilMarking(false);
};
window.epubFixtureSelectPassage = () => {
  const contents = view.renderer.getContents();
  for (const { doc, index } of contents) {
    const paragraph = Array.from(doc.querySelectorAll("p")).find((item) => item.textContent.trim());
    if (!paragraph) continue;
    const range = doc.createRange();
    range.selectNodeContents(paragraph);
    const selected = doc.getSelection();
    selected.removeAllRanges();
    selected.addRange(range);
    const passage = selection(doc, index);
    window.webkit.messageHandlers.selection.postMessage(passage);
    const rect = range.getBoundingClientRect();
    let cfiRoundTrip = false;
    try {
      const resolved = passage && view.resolveCFI(passage.cfi);
      cfiRoundTrip = resolved?.index === index && resolved.anchor(doc).toString() === passage.text;
    } catch {}
    return {
      contentsCount: contents.length,
      sectionIndex: index,
      paragraphCount: doc.querySelectorAll("p").length,
      rangeCount: selected.rangeCount,
      collapsed: selected.isCollapsed,
      targetVisible:
        rect.width > 0 &&
        rect.height > 0 &&
        rect.bottom > 0 &&
        rect.right > 0 &&
        rect.top < doc.defaultView.innerHeight &&
        rect.left < doc.defaultView.innerWidth,
      textChars: passage?.text.length ?? 0,
      cfiChars: passage?.cfi.length ?? 0,
      cfiRoundTrip,
    };
  }
  return { contentsCount: contents.length, sectionIndex: -1, paragraphCount: 0 };
};
window.epubFixturePencilRelease = (repeating) => {
  if (repeating && lastPencilRelease) {
    window.webkit.messageHandlers.pencilRelease.postMessage(lastPencilRelease);
    return;
  }
  window.epubFixtureSelectPassage();
  for (const { doc, index } of view.renderer.getContents()) {
    if (!selection(doc, index)) continue;
    setPencilMarking(true);
    releasePencilPassage(doc, index, pencilOperationID());
    return;
  }
};
const pending = [];
const sendResource = (path) =>
  new Promise((resolve, reject) => {
    if (closed || pending.length >= 32) return reject(new Error("The resource queue is unavailable."));
    pending.push({ path, resolve, reject });
    drain();
  });
const drain = () => {
  while (!closed && active < 2 && pending.length) {
    const item = pending.shift();
    active++;
    window.webkit.messageHandlers.resource
      .postMessage(item.path)
      .then(item.resolve, item.reject)
      .finally(() => {
        active--;
        drain();
      });
  }
};
const recordedStep = (step, phase, index, started) => {
  window.webkit.messageHandlers.recordedTransition?.postMessage({ step, phase, index, durationMs: Math.round(performance.now() - started) });
};
const settle = async (recordedIndex = null, pass = 1) => {
  const diagnostic = (step, phase, started) => {
    if (recordedIndex !== null) recordedStep(`${step}${pass}`, phase, recordedIndex, started);
  };
  for (const { doc } of view.renderer.getContents()) {
    let started = performance.now();
    diagnostic("customFonts", "start", started);
    await settleCustomFonts(doc);
    diagnostic("customFonts", "end", started);
    started = performance.now();
    diagnostic("fonts", "start", started);
    await doc.fonts.ready;
    diagnostic("fonts", "end", started);
    started = performance.now();
    diagnostic("images", "start", started);
    await Promise.all(
      Array.from(doc.images, async (image) => {
        if (!image.complete)
          await new Promise((resolve) => {
            image.addEventListener("load", resolve, { once: true });
            image.addEventListener("error", resolve, { once: true });
          });
        if (image.complete && image.naturalWidth) await image.decode().catch(() => {});
      }),
    );
    diagnostic("images", "end", started);
  }
  const frameStarted = performance.now();
  diagnostic("frameA", "start", frameStarted);
  await new Promise((resolve) =>
    requestAnimationFrame(() => {
      diagnostic("frameA", "end", frameStarted);
      const nextFrameStarted = performance.now();
      diagnostic("frameB", "start", nextFrameStarted);
      requestAnimationFrame(() => {
        diagnostic("frameB", "end", nextFrameStarted);
        resolve();
      });
    }),
  );
};
const location = () => {
  const value = view.lastLocation;
  if (typeof value?.cfi !== "string" || value.cfi.length > 2000 || !Number.isFinite(value.fraction) || value.fraction < 0 || value.fraction > 1)
    throw new Error("The reading position is unavailable.");
  return {
    cfi: value.cfi,
    percentage: value.fraction * 100,
    chapterIndex: value.section.current,
    rightToLeft: view.isFixedLayout ? publication.dir === "rtl" : view.renderer.getAttribute("dir") === "rtl",
    fixedLayout: view.isFixedLayout,
    page: !view.isFixedLayout && !view.renderer.scrolled ? view.renderer.page : null,
    pageTotal: !view.isFixedLayout && !view.renderer.scrolled ? Math.max(1, view.renderer.pages - 2) : null,
    remainingMinutes: Number.isFinite(value.time?.total) ? Math.max(0, Math.ceil(value.time.total)) : null,
    chapterLabel: String(value.tocItem?.label ?? "").slice(0, 500),
    ...publicationPosition(value),
  };
};
const go = async (target, smooth = false, recorded = false) => {
  const opened = publication;
  if (closed || !opened) throw new Error("The reader closed.");
  resourceBytes = 0;
  const resolved = await view.resolveNavigation(target);
  if (!resolved || !Number.isInteger(resolved.index) || !publication.sections[resolved.index])
    throw new Error("This passage is unavailable in the publication.");
  const renderer = view.renderer;
  await withProgrammaticMovement(renderer, smooth, async () => {
    let started = performance.now();
    if (recorded) recordedStep("navigation1", "start", resolved.index, started);
    const section = publication.sections[resolved.index];
    const load = section.load;
    const traceLoad = recorded && window.webkit.messageHandlers.recordedTransition;
    if (traceLoad)
      section.load = async (...args) => {
        const loadStarted = performance.now();
        recordedStep("sectionLoad", "start", resolved.index, loadStarted);
        const result = await load.apply(section, args);
        recordedStep("sectionLoad", "end", resolved.index, loadStarted);
        recordedSectionLoad = { index: resolved.index, started: performance.now() };
        recordedStep("iframeLoad", "start", resolved.index, recordedSectionLoad.started);
        return result;
      };
    try {
      await renderer.goTo({ ...resolved, smooth });
    } finally {
      if (traceLoad) section.load = load;
      recordedSectionLoad = null;
    }
    if (recorded) recordedStep("navigation1", "end", resolved.index, started);
    await settle(recorded ? resolved.index : null, 1);
    if (closed || opened !== publication || renderer !== view.renderer) throw new Error("The reader closed.");
    started = performance.now();
    if (recorded) recordedStep("navigation2", "start", resolved.index, started);
    await renderer.goTo(resolved);
    if (recorded) recordedStep("navigation2", "end", resolved.index, started);
    await settle(recorded ? resolved.index : null, 2);
  });
  if (closed || opened !== publication || renderer !== view.renderer) throw new Error("The reader closed.");
  if (!view.renderer.getContents().some((item) => item.index === resolved.index)) throw new Error("The requested passage could not be opened.");
  return location();
};
const notify = () => {
  if (closed) return;
  try {
    window.webkit.messageHandlers.location.postMessage({ ...location(), source: narrationMovement > 0 ? "narration" : "text" });
  } catch {}
};
const selection = (doc, index) => {
  const selected = doc.getSelection();
  if (!selected || selected.rangeCount !== 1 || selected.isCollapsed) return null;
  const range = selected.getRangeAt(0);
  const text = range.toString();
  const cfi = view.getCFI(index, range);
  if (!text || text.length > 16000 || cfi.length > 2000) return null;
  const metadataLanguage = publication?.metadata?.language;
  const rawLanguage = Array.isArray(metadataLanguage) ? metadataLanguage[0] : metadataLanguage;
  const language = typeof rawLanguage === "string" && rawLanguage.length <= 64 ? rawLanguage : (view.language?.canonical ?? "en");
  return { cfi, text, language };
};
const applyDocumentStyles = (doc) => {
  let style = doc.getElementById("bookorbit-reader-style");
  if (!style) {
    style = doc.createElement("style");
    style.id = "bookorbit-reader-style";
    doc.head.append(style);
  }
  style.textContent = currentStyles;
};
view.addEventListener("load", ({ detail: { doc, index } }) => {
  if (recordedSectionLoad?.index === index) {
    recordedStep("iframeLoad", "end", index, recordedSectionLoad.started);
    recordedSectionLoad.started = performance.now();
    recordedStep("sectionRender", "start", index, recordedSectionLoad.started);
  }
  if (view.isFixedLayout) applyDocumentStyles(doc);
  renderPassageAnnotations(doc, index);
  let pencilStart;
  doc.addEventListener(
    "pointerdown",
    (event) => {
      if (!annotationWriting || event.pointerType !== "pen") return;
      const caret = doc.caretRangeFromPoint(event.clientX, event.clientY);
      if (!caret) return;
      pencilStart = { node: caret.startContainer, offset: caret.startOffset, operationId: pencilOperationID() };
      setPencilMarking(true);
      event.preventDefault();
    },
    { passive: false },
  );
  doc.addEventListener(
    "pointermove",
    (event) => {
      if (!pencilStart || !annotationWriting || event.pointerType !== "pen") return;
      const caret = doc.caretRangeFromPoint(event.clientX, event.clientY);
      if (!caret) return;
      doc.getSelection().setBaseAndExtent(pencilStart.node, pencilStart.offset, caret.startContainer, caret.startOffset);
      event.preventDefault();
    },
    { passive: false },
  );
  doc.addEventListener(
    "pointerup",
    (event) => {
      if (!pencilStart || event.pointerType !== "pen") return;
      const operationId = pencilStart.operationId;
      pencilStart = null;
      releasePencilPassage(doc, index, operationId);
      event.preventDefault();
    },
    { passive: false },
  );
  doc.addEventListener("pointercancel", () => {
    pencilStart = null;
    setPencilMarking(false);
  });
  doc.addEventListener("click", (event) => {
    if (closed || pencilStart || !doc.getSelection()?.isCollapsed) return;
    const caret = doc.caretRangeFromPoint(event.clientX, event.clientY);
    if (!caret) return;
    const item = matchedPassageAnnotation(doc, index, caret);
    if (item) window.webkit.messageHandlers.passageAnnotation.postMessage(item.id);
  });
  doc.addEventListener("selectionchange", () => {
    if (!closed) window.webkit.messageHandlers.selection.postMessage(selection(doc, index));
    const selected = doc.getSelection();
    if (closed || pencilMarking || !selected?.rangeCount || selected.isCollapsed) return;
    const item = matchedPassageAnnotation(doc, index, selected.getRangeAt(0));
    if (item?.kind === "handwriting") window.webkit.messageHandlers.passageAnnotation.postMessage(item.id);
  });
});
view.addEventListener("relocate", notify);
const decodeText = (data) => {
  const encoding =
    data[0] === 0xff && data[1] === 0xfe
      ? "utf-16le"
      : data[0] === 0xfe && data[1] === 0xff
        ? "utf-16be"
        : data[0] === 0x00 && data[1] === 0x3c
          ? "utf-16be"
          : data[0] === 0x3c && data[1] === 0x00
            ? "utf-16le"
            : "utf-8";
  return new TextDecoder(encoding, { fatal: true }).decode(data);
};
window.epubOpen = async (info, cfi, settings, formatting) => {
  closed = false;
  const manifest = new Map(info.manifest.map((item) => [item.href, item]));
  const paths = new Set(["META-INF/container.xml", info.containerPath, ...(info.optionalFiles ?? []), ...manifest.keys()]);
  const bytes = async (path) => {
    if (!paths.has(path)) return null;
    const size = manifest.get(path)?.size ?? 0;
    if (resourceBytes + size > 32 * 1024 * 1024) throw new Error("This page exceeds the publication resource limit.");
    resourceBytes += size;
    const encoded = await sendResource(path);
    return Uint8Array.from(atob(encoded), (value) => value.charCodeAt(0));
  };
  publication = await new EPUB({
    loadText: async (path) => {
      const data = await bytes(path);
      return data ? decodeText(data) : null;
    },
    loadBlob: async (path, type) => {
      const data = await bytes(path);
      return data ? new Blob([data], { type: type ?? manifest.get(path)?.mediaType }) : null;
    },
    getSize: (path) => manifest.get(path)?.size ?? 0,
  }).init();
  publication.transformTarget.addEventListener("data", ({ detail }) => {
    if (!["application/xhtml+xml", "text/html"].includes(detail.type)) return;
    detail.data = Promise.resolve(detail.data).then((text) => {
      const doc = new DOMParser().parseFromString(text, detail.type);
      const policy = doc.createElementNS("http://www.w3.org/1999/xhtml", "meta");
      policy.setAttribute("http-equiv", "Content-Security-Policy");
      policy.setAttribute(
        "content",
        "default-src 'none'; script-src 'none'; connect-src 'none'; object-src 'none'; frame-src 'none'; media-src 'none'; style-src 'unsafe-inline' blob:; img-src blob: data:; font-src blob: data: bookorbit-font:",
      );
      doc.querySelector("head")?.prepend(policy);
      return new XMLSerializer().serializeToString(doc);
    });
  });
  return await openPublication(publication, cfi, settings, formatting);
};
const openPublication = async (book, cfi, settings, formatting) => {
  closed = false;
  publication = book;
  publication.rendition ??= {};
  publisherSpread = publication.rendition.spread;
  if (settings.fixedLayoutSpread === "none") publication.rendition.spread = "none";
  await view.open(publication);
  view.renderer.disablePointerNavigation?.();
  view.renderer.addEventListener("create-overlayer", ({ detail: { index } }) => {
    if (recordedSectionLoad?.index === index) recordedStep("sectionRender", "end", index, recordedSectionLoad.started);
  });
  view.renderer.addEventListener("before-section-load", () => {
    resourceBytes = 0;
  });
  view.renderer.addEventListener("navigation-error", ({ detail }) => {
    if (!closed)
      window.webkit.messageHandlers.readerError.postMessage(
        String(detail?.message ?? "This section could not be opened. Try Contents or reopen the reader.").slice(0, 500),
      );
  });
  await window.epubConfigure(settings, formatting, cfi);
  return location();
};
window.epubOpenDelivered = async (format, size, cfi, settings, formatting) => {
  closed = false;
  const read = async (offset, length) => {
    if (
      !Number.isSafeInteger(offset) ||
      !Number.isSafeInteger(length) ||
      offset < 0 ||
      length < 0 ||
      offset + length > size ||
      length > 32 * 1024 * 1024
    )
      throw new Error("The delivered ebook range is invalid.");
    const bytes = new Uint8Array(length);
    for (let cursor = 0; cursor < length; cursor += 1024 * 1024) {
      const count = Math.min(1024 * 1024, length - cursor);
      const encoded = await sendResource({ offset: offset + cursor, length: count });
      const chunk = Uint8Array.from(atob(encoded), (character) => character.charCodeAt(0));
      if (chunk.length !== count) throw new Error("The delivered ebook changed while opening.");
      bytes.set(chunk, cursor);
    }
    return bytes;
  };
  try {
    const { book, outline } = await makeDeliveredBook(format, size, read);
    const position = await openPublication(book, cfi, settings, formatting);
    return { location: position, outline };
  } catch (error) {
    publication?.destroy?.();
    return { failure: String(error?.message ?? "This ebook could not be decoded.").slice(0, 500) };
  }
};
window.epubPrepareFonts = (faces, settings) =>
  prepareCustomFonts(
    faces,
    settings,
    view.renderer.getContents().map(({ doc }) => doc),
  );
window.epubConfigure = async (settings, formatting, cfi) => {
  if (view.isFixedLayout) {
    const spread = settings.fixedLayoutSpread === "none" ? "none" : publisherSpread;
    if (publication.rendition.spread !== spread) {
      view.close();
      publication.rendition.spread = spread;
      await view.open(publication);
    }
  }
  const renderer = view.renderer;
  configureCustomFont(settings, formatting && !view.isFixedLayout);
  if (!view.isFixedLayout && settings.flow === "scrolled")
    renderer.setAttribute("continuous-axis", settings.nativeContinuousAxis === "horizontal" ? "horizontal" : "vertical");
  else renderer.removeAttribute("continuous-axis");
  renderer.setAttribute("flow", view.isFixedLayout ? "paginated" : settings.flow);
  renderer.setAttribute("max-column-count", String(settings.maxColumnCount));
  renderer.setAttribute("gap", `${settings.gap * 100}%`);
  renderer.setAttribute("max-inline-size", String(settings.maxInlineSize));
  renderer.setAttribute("max-block-size", String(settings.maxBlockSize));
  renderer.removeAttribute("animated");
  const theme = themes.find((item) => item.name === settings.themeName) ?? themes[0];
  const palette = settings.isDark ? theme.dark : theme.light;
  document.body.style.background = palette.bg;
  const body =
    formatting && !view.isFixedLayout
      ? `
    ${settings.fontFamily ? `font-family: ${fontFamilyCSS(settings.fontFamily)} !important;` : ""}
    ${settings.fontFamily?.startsWith("__") ? "font-synthesis: none !important;" : ""}
    font-weight: ${settings.fontWeight} !important; font-style: ${settings.fontStyle} !important;
    font-size: ${settings.fontSize}px !important; line-height: ${settings.lineHeight} !important;
    text-align: ${settings.justify ? "justify" : "start"} !important;
    hyphens: ${settings.hyphenate ? "auto" : "none"} !important;
    ${settings.letterSpacing == null ? "" : `letter-spacing: ${settings.letterSpacing}em !important;`}
    ${settings.wordSpacing == null ? "" : `word-spacing: ${settings.wordSpacing}em !important;`}`
      : "";
  const paragraph =
    formatting && !view.isFixedLayout
      ? `
    ${settings.paragraphSpacing ? `margin-block: ${settings.paragraphSpacing}em !important;` : ""}
    ${settings.textIndent == null ? "" : `text-indent: ${settings.textIndent}em !important;`}`
      : "";
  currentStyles = `
    ${customFontCSS()}
    :root { color-scheme: ${settings.isDark ? "dark" : "light"}; }
    body { color: ${palette.fg}; background: ${palette.bg}; ${body} }
    ${formatting && !view.isFixedLayout && settings.fontFamily ? "body * { font-family: inherit !important; }" : ""}
    a { color: ${palette.link}; }
    p { ${paragraph} }
    ::highlight(bookorbit-recorded), ::highlight(bookorbit-speech) { background-color: Highlight; color: HighlightText; }
    ::highlight(bookorbit-annotations) { background-color: Mark; color: MarkText; }
  `;
  if (renderer.setStyles) renderer.setStyles(currentStyles);
  else for (const { doc } of renderer.getContents()) applyDocumentStyles(doc);
  return await go(cfi || 0);
};
window.epubTurn = async (forward, smooth = false) => {
  resourceBytes = 0;
  await withProgrammaticMovement(view.renderer, smooth, () => (forward ? view.next() : view.prev()));
  await settle();
  return location();
};
window.epubLocation = () => {
  view.renderer.captureLocation?.();
  return location();
};
window.epubGo = go;
window.epubPreserveLayout = async (target) => {
  const hasSelection = view.renderer.getContents().some(({ doc }) => {
    const selected = doc.getSelection();
    return selected?.rangeCount === 1 && !selected.isCollapsed;
  });
  if (!hasSelection) return go(target);
  await settle();
  return location();
};
window.epubGoFraction = (fraction, smooth) => go(fractionTarget(fraction), smooth);
window.epubPositionPreview = (target) => {
  const opened = publication;
  resourceBytes = 0;
  return describePosition(view, opened, target, () => !closed && opened === publication);
};
window.epubSearchStart = async (query) => {
  searchState?.iterator?.return?.();
  searchState = { query, index: 0, iterator: null };
  return await window.epubSearchNext();
};
window.epubSearchNext = async () => {
  if (!searchState) throw new Error("Start a book search first.");
  const state = searchState;
  const results = [];
  let scanned = 0;
  while (!closed && state === searchState && state.index < publication.sections.length && scanned < 4) {
    if (!state.iterator) {
      resourceBytes = 0;
      const doc = await publication.sections[state.index].createDocument();
      const matcher = searchMatcher(textWalker, { defaultLocale: view.language?.canonical ?? "en" });
      state.iterator = matcher(doc, state.query);
    }
    const next = state.iterator.next();
    if (next.done) {
      state.iterator = null;
      state.index++;
      scanned++;
      continue;
    }
    const cfi = view.getCFI(state.index, next.value.range);
    const excerpt = next.value.excerpt;
    const text = [excerpt.pre, excerpt.match, excerpt.post].filter(Boolean).join("");
    if (cfi.length <= 2000) results.push({ id: cfi, text: text.slice(0, 500) });
    if (results.length === 50) break;
  }
  if (closed || state !== searchState) throw new Error("The search ended.");
  return { items: results, nextChapter: state.index, complete: state.index >= publication.sections.length };
};
window.epubSearchCancel = () => {
  searchState?.iterator?.return?.();
  searchState = null;
};
window.epubClose = () => {
  pencilMarking = false;
  lastPencilRelease = undefined;
  passageAnnotations = [];
  annotationWriting = false;
  closed = true;
  window.epubSearchCancel();
  clearCustomFonts();
  for (const item of pending.splice(0)) item.reject(new Error("The reader closed."));
  view.close();
  publication = null;
};

const speechNodes = (doc) =>
  doc.createTreeWalker(doc.body ?? doc.documentElement, NodeFilter.SHOW_TEXT, {
    acceptNode: (node) => {
      if (!node.nodeValue || node.parentElement?.closest("script, style, [hidden], [aria-hidden='true']")) return NodeFilter.FILTER_REJECT;
      if (doc.defaultView) {
        for (let element = node.parentElement; element; element = element.parentElement) {
          const style = doc.defaultView.getComputedStyle(element);
          if (style.display === "none" || style.visibility === "hidden") return NodeFilter.FILTER_REJECT;
        }
      }
      return NodeFilter.FILTER_ACCEPT;
    },
  });
const speechStart = (doc, anchor) => {
  const range = typeof anchor === "function" ? anchor(doc) : null;
  if (range?.startContainer) {
    range.collapse(true);
    return range;
  }
  const start = doc.createRange();
  start.selectNodeContents(doc.body ?? doc.documentElement);
  start.collapse(true);
  return start;
};
const speechParts = (doc, start, maximum, knownBlock) => {
  let block = knownBlock;
  if (!block) {
    for (const candidate of getBlocks(doc)) {
      if (candidate.comparePoint(start.startContainer, start.startOffset) !== 1) {
        block = candidate;
        break;
      }
    }
  }
  const walker = speechNodes(doc);
  walker.currentNode = start.startContainer;
  const initialNode =
    start.startContainer.nodeType === Node.TEXT_NODE && walker.filter.acceptNode(start.startContainer) === NodeFilter.FILTER_ACCEPT
      ? start.startContainer
      : walker.nextNode();
  const rawParts = [];
  let length = 0;
  let next;
  for (let node = initialNode; node; node = walker.nextNode()) {
    if (start.comparePoint(node, node.nodeValue.length) < 0) continue;
    const offset = node === start.startContainer ? start.startOffset : 0;
    if (offset === node.nodeValue.length) continue;
    if ((block && block.comparePoint(node, offset) > 0) || length >= maximum + 256) {
      next = { node, offset };
      break;
    }
    let count = Math.min(node.nodeValue.length - offset, maximum + 256 - length);
    if (block?.endContainer === node) count = Math.min(count, block.endOffset - offset);
    const last = node.nodeValue.charCodeAt(offset + count - 1);
    if (count < node.nodeValue.length - offset && last >= 0xd800 && last <= 0xdbff) count--;
    if (!count) {
      next = { node, offset };
      break;
    }
    rawParts.push({ node, offset, count });
    length += count;
    if (offset + count < node.nodeValue.length) {
      next = { node, offset: offset + count };
      break;
    }
  }
  const rawText = rawParts.map((part) => part.node.nodeValue.slice(part.offset, part.offset + part.count)).join("");
  let boundary = rawText.length;
  if (boundary > maximum) {
    boundary = 0;
    const segmenter = new Intl.Segmenter(view.language?.canonical ?? "en", { granularity: "grapheme" });
    for (const item of segmenter.segment(rawText)) {
      const end = item.index + item.segment.length;
      if (end > maximum) break;
      boundary = end;
    }
    if (!boundary) throw new Error("A grapheme exceeds the speech chunk limit.");
  }
  const parts = [];
  let remaining = boundary;
  for (const part of rawParts) {
    if (!remaining) {
      next = { node: part.node, offset: part.offset };
      break;
    }
    const count = Math.min(remaining, part.count);
    parts.push({ ...part, count });
    remaining -= count;
    if (count < part.count) {
      next = { node: part.node, offset: part.offset + count };
      break;
    }
  }
  return { parts, next };
};
const partRange = (doc, parts, offset, length) => {
  let remaining = offset;
  let start;
  let end;
  for (const part of parts) {
    if (!start && remaining < part.count) start = { node: part.node, offset: part.offset + remaining };
    if (start) {
      const available = part.count - remaining;
      if (length <= available) {
        end = { node: part.node, offset: part.offset + remaining + length };
        break;
      }
      length -= available;
      remaining = 0;
    } else remaining -= part.count;
  }
  if (!start || !end) throw new Error("The spoken word range is unavailable.");
  const range = doc.createRange();
  range.setStart(start.node, start.offset);
  range.setEnd(end.node, end.offset);
  return range;
};
let speechHighlightGeneration = 0;
let speechChunkCache;
const liveSpeechDocument = async (index, target) => {
  let content = view.renderer.getContents().find((item) => item.index === index);
  if (!content) {
    await go(target);
    content = view.renderer.getContents().find((item) => item.index === index);
  }
  if (!content?.doc?.defaultView) throw new Error("The spoken passage could not be opened.");
  return content.doc;
};
window.epubSpeechChunk = async (cfi, maximum) => {
  const generation = speechHighlightGeneration;
  if (!Number.isInteger(maximum) || maximum < 2 || maximum > 2048 || closed) throw new Error("The speech text limit is invalid.");
  const target = cfi ?? location().cfi;
  const legacy = /^tts:(\d+):(\d+)$/.exec(target);
  const resolved = legacy
    ? {
        index: Number(legacy[1]),
        anchor: (doc) => {
          let index = 0;
          for (const range of getBlocks(doc)) {
            if (index++ === Number(legacy[2])) return range;
          }
          throw new Error("The saved speech block is unavailable.");
        },
      }
    : view.resolveCFI(target);
  if (!resolved || resolved.index < 0 || resolved.index >= publication.sections.length) throw new Error("The speech passage is unavailable.");
  let index = resolved.index;
  let anchor = resolved.anchor;
  for (; index < publication.sections.length; index++) {
    if (index !== resolved.index && publication.sections[index].linear === "no") continue;
    const navigation = index === resolved.index && !legacy ? target : view.getCFI(index);
    const doc = await liveSpeechDocument(index, navigation);
    if (closed || generation !== speechHighlightGeneration) throw new Error("Speech passage loading was cancelled.");
    let startRange = speechStart(doc, anchor);
    let extracted = speechParts(doc, startRange, maximum);
    let text = extracted.parts.map((part) => part.node.nodeValue.slice(part.offset, part.offset + part.count)).join("");
    while (!text.trim() && extracted.next) {
      startRange = doc.createRange();
      startRange.setStart(extracted.next.node, extracted.next.offset);
      startRange.collapse(true);
      extracted = speechParts(doc, startRange, maximum);
      text = extracted.parts.map((part) => part.node.nodeValue.slice(part.offset, part.offset + part.count)).join("");
    }
    const { parts, next } = extracted;
    anchor = null;
    if (!parts.length || !text.trim()) continue;
    const start = partRange(doc, parts, 0, 1);
    start.collapse(true);
    let nextCFI = null;
    if (next) {
      const range = doc.createRange();
      range.setStart(next.node, next.offset);
      range.collapse(true);
      nextCFI = view.getCFI(index, range);
    } else {
      const nextIndex = publication.sections.findIndex((item, candidate) => candidate > index && item.linear !== "no");
      if (nextIndex >= 0) nextCFI = view.getCFI(nextIndex);
    }
    const result = { cfi: view.getCFI(index, start), text, chapterIndex: index, nextCFI };
    speechChunkCache = { cfi: result.cfi, doc, parts };
    return result;
  }
  return null;
};
window.epubPreviousSpeechChunk = async (cfi, maximum) => {
  const generation = speechHighlightGeneration;
  const checkActive = () => {
    if (closed || generation !== speechHighlightGeneration) throw new Error("Speech passage loading was cancelled.");
  };
  if (!Number.isInteger(maximum) || maximum < 2 || maximum > 2048 || closed) throw new Error("The speech text limit is invalid.");
  const resolved = view.resolveCFI(cfi);
  if (!resolved || resolved.index < 0 || resolved.index >= publication.sections.length) throw new Error("The speech passage is unavailable.");
  const doc = await liveSpeechDocument(resolved.index, cfi);
  checkActive();
  const target = await previousSpeechStart(doc, speechStart(doc, resolved.anchor), maximum, getBlocks, speechParts, checkActive);
  checkActive();
  return window.epubSpeechChunk(view.getCFI(resolved.index, target), maximum);
};
window.epubHighlightSpeech = async (chunkCFI, offset, length) => {
  const generation = speechHighlightGeneration;
  if (!Number.isInteger(offset) || !Number.isInteger(length) || offset < 0 || length < 1 || offset + length > 2048)
    throw new Error("The spoken word range is invalid.");
  const resolved = view.resolveCFI(chunkCFI);
  if (!resolved || resolved.index < 0) throw new Error("The spoken passage is unavailable.");
  const doc = await liveSpeechDocument(resolved.index, chunkCFI);
  if (closed || generation !== speechHighlightGeneration) throw new Error("Speech highlighting was cancelled.");
  const parts =
    speechChunkCache?.cfi === chunkCFI && speechChunkCache.doc === doc
      ? speechChunkCache.parts
      : speechParts(doc, speechStart(doc, resolved.anchor), offset + length).parts;
  const word = partRange(doc, parts, offset, length);
  const targetCFI = view.getCFI(resolved.index, word);
  await go(targetCFI);
  if (closed || generation !== speechHighlightGeneration) throw new Error("Speech highlighting was cancelled.");
  clearSpeechPaint();
  const content = view.renderer.getContents().find((item) => item.index === resolved.index);
  const range = view.resolveCFI(targetCFI).anchor(content.doc);
  if (!content.doc.defaultView.CSS.highlights || !content.doc.defaultView.Highlight)
    throw new Error("Word highlighting is unavailable on this device.");
  content.doc.defaultView.CSS.highlights.set("bookorbit-speech", new content.doc.defaultView.Highlight(range));
  const start = range.cloneRange();
  start.collapse(true);
  return { cfi: view.getCFI(resolved.index, start), chapterIndex: resolved.index };
};
const clearSpeechPaint = () => {
  for (const { doc } of view.renderer.getContents()) doc.defaultView.CSS.highlights?.delete("bookorbit-speech");
};
window.epubClearSpeechHighlight = () => {
  speechHighlightGeneration++;
  speechChunkCache = null;
  clearSpeechPaint();
};
window.addEventListener("pagehide", () => {
  closed = true;
  clearCustomFonts();
  window.epubClearSpeechHighlight();
  window.epubClearRecordedHighlight();
  searchState?.iterator?.return?.();
  for (const item of pending.splice(0)) item.reject(new Error("The publication closed."));
  view.close();
  publication?.destroy?.();
});

let recordedGeneration = 0;
const recordedRange = (doc, anchor) => {
  const value = typeof anchor === "function" ? anchor(doc) : doc.body;
  const target = value === 0 ? doc.body : value;
  if (!target) throw new Error("The recorded segment is unavailable in this publication.");
  if (target.startContainer && target.endContainer) return target;
  const range = doc.createRange();
  range.selectNodeContents(target);
  return range;
};
const clearRecordedPaint = () => {
  for (const { doc } of view.renderer.getContents()) doc.defaultView.CSS.highlights?.delete("bookorbit-recorded");
};
window.epubRecordedMatch = async (items, cfi) => {
  if (closed || !Array.isArray(items) || items.length > 128) throw new Error("The recorded clip page is invalid.");
  const selected = view.resolveCFI(cfi);
  if (!selected) throw new Error("The chosen passage is unavailable.");
  const doc = await liveSpeechDocument(selected.index, cfi);
  const point = selected.anchor(doc);
  for (const item of items) {
    const target = item.textFragment ? `${item.textHref}#${item.textFragment}` : item.textHref;
    const resolved = await view.resolveNavigation(target);
    if (!resolved || resolved.index !== selected.index) continue;
    const range = recordedRange(doc, resolved.anchor);
    if (range.comparePoint(point.startContainer, point.startOffset) === 0 || point.comparePoint(range.startContainer, range.startOffset) === 0)
      return item.index;
  }
  return null;
};
window.epubRecordedHighlight = async (href, follow) => {
  const diagnosticStarted = performance.now();
  let resolved;
  let statement = "resolve";
  try {
    const generation = recordedGeneration;
    resolved = await view.resolveNavigation(href);
    if (!resolved || !Number.isInteger(resolved.index)) throw new Error("The recorded segment is unavailable.");
    statement = "follow";
    if (follow) await go(href, false, true);
    if (closed || generation !== recordedGeneration) throw new Error("Recorded highlighting was cancelled.");
    statement = "clearPaint";
    clearRecordedPaint();
    statement = "document";
    const content = view.renderer.getContents().find((item) => item.index === resolved.index);
    const doc = content?.doc ?? (await publication.sections[resolved.index].createDocument());
    if (closed || generation !== recordedGeneration) throw new Error("Recorded highlighting was cancelled.");
    statement = "range";
    const range = recordedRange(doc, resolved.anchor);
    const point = range.cloneRange();
    point.collapse(true);
    statement = "cfi";
    const cfi = view.getCFI(resolved.index, point);
    statement = "paint";
    if (content) {
      if (!doc.defaultView.CSS.highlights || !doc.defaultView.Highlight) throw new Error("Segment highlighting is unavailable on this device.");
      doc.defaultView.CSS.highlights.set("bookorbit-recorded", new doc.defaultView.Highlight(range));
    }
    statement = "result";
    return { cfi, chapterIndex: resolved.index, text: range.toString().slice(0, 500), percentage: follow ? location().percentage : null };
  } catch (error) {
    const names = new Set(["Error", "TypeError", "ReferenceError", "RangeError", "SyntaxError", "SecurityError", "InvalidStateError", "WrongDocumentError", "NotFoundError"]);
    const name = names.has(error?.name) ? error.name : "UnknownError";
    const source = /reader\.js:(\d+):(\d+)/.exec(String(error?.stack ?? "").slice(0, 4096));
    const messages = new Map([
      ["The reading position is unavailable.", "readingPosition"],
      ["Recorded highlighting was cancelled.", "cancelled"],
      ["The recorded segment is unavailable.", "segmentUnavailable"],
      ["The recorded segment is unavailable in this publication.", "anchorUnavailable"],
      ["Segment highlighting is unavailable on this device.", "highlightUnavailable"],
      ["The requested passage could not be opened.", "passageUnavailable"],
      ["The reader closed.", "closed"],
    ]);
    window.webkit.messageHandlers.recordedTransition?.postMessage({
      step: "highlightException", phase: "fail", index: resolved?.index ?? 0, statement, durationMs: Math.round(performance.now() - diagnosticStarted),
      errorName: name, line: source ? Number(source[1]) : 0, column: source ? Number(source[2]) : 0,
      messageCode: messages.get(error?.message) ?? "engineException",
    });
    throw error;
  }
};
window.epubClearRecordedHighlight = () => {
  recordedGeneration++;
  clearRecordedPaint();
};

for (const name of ["epubSpeechChunk", "epubPreviousSpeechChunk", "epubHighlightSpeech", "epubRecordedMatch", "epubRecordedHighlight"]) {
  const operation = window[name];
  if (typeof operation !== "function") continue;
  window[name] = async (...arguments_) => {
    narrationMovement++;
    try {
      return await operation(...arguments_);
    } finally {
      narrationMovement--;
    }
  };
}
