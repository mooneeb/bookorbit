import "/foliate/view.js";

const view = document.querySelector("foliate-view");
const problem = document.querySelector("#problem");
let groups = [];
let font = 24;
let generation = 0;
let sourceHash = "";
let scheduled = false;
let sequence = 0;
let chapter = Number(new URL(location.href).searchParams.get("chapter") || 0);
let focusCFI = null;
const send = (message) => {
  const payload = JSON.parse(JSON.stringify(message));
  window.lastReflowMessage = payload;
  window.webkit?.messageHandlers?.reflow?.postMessage(payload);
};
const fail = (error) => {
  problem.textContent = `The sample could not be opened. ${error.message || error}`;
  send({ type: "error", message: problem.textContent });
};
window.addEventListener("error", (event) => fail(event.error || event.message));
window.addEventListener("unhandledrejection", (event) => fail(event.reason));

function fragments(range) {
  const frame = range.startContainer.ownerDocument.defaultView.frameElement.getBoundingClientRect();
  return [...range.getClientRects()]
    .filter(
      (rect) => rect.width > 0 && rect.height > 0 && [rect.left, rect.top, rect.width, rect.height, frame.left, frame.top].every(Number.isFinite),
    )
    .map((rect) => ({
      x: frame.left + rect.left,
      y: frame.top + rect.top,
      width: rect.width,
      height: rect.height,
    }));
}

function measure(reason = "layout") {
  const started = performance.now();
  const contents = view.renderer?.getContents() || [];
  const resolved = groups.map((group) => {
    try {
      if (group.sourceHash !== sourceHash) return { id: group.id, status: "source-mismatch" };
      const locator = view.resolveCFI(group.cfi);
      const content = contents.find((item) => item.index === locator.index);
      if (!content) return { id: group.id, status: "different-chapter" };
      const range = locator.anchor(content.doc);
      if (range.toString() !== group.quote) return { id: group.id, status: "quote-mismatch" };
      const rects = fragments(range);
      const visible = rects.filter((r) => r.x + r.width > 0 && r.x < innerWidth && r.y + r.height > 0 && r.y < innerHeight);
      return { id: group.id, status: visible.length ? "resolved" : "offscreen", quote: range.toString(), rects, visible, index: locator.index };
    } catch (error) {
      return { id: group.id, status: "unresolved", message: String(error) };
    }
  });
  send({
    type: "geometry",
    generation,
    sequence: ++sequence,
    reason,
    font,
    sourceHash,
    flow: view.renderer.getAttribute("flow"),
    viewport: { width: innerWidth, height: innerHeight },
    groups: resolved,
    location: view.lastLocation ? { cfi: view.lastLocation.cfi, section: view.lastLocation.section, location: view.lastLocation.location } : null,
    measurementMilliseconds: performance.now() - started,
    activeResources: contents.length,
    renderer: "BookOrbit Foliate at ce118e3890ea8c9019857cb7556552cdc9992f8e",
  });
}
function schedule(reason = "layout") {
  if (scheduled) return;
  scheduled = true;
  requestAnimationFrame(() => {
    scheduled = false;
    measure(reason);
  });
}

view.addEventListener("load", ({ detail: { doc } }) => {
  doc.addEventListener("selectionchange", () => {
    const selection = doc.getSelection();
    if (selection?.toString().trim()) send({ type: "selection", text: selection.toString() });
  });
  doc.fonts.ready.then(() => schedule("fonts-ready"));
});

window.reflow = {
  setGroups(value, activeCFI) {
    groups = value;
    focusCFI = activeCFI;
    schedule("groups-restored");
  },
  select() {
    for (const { doc, index } of view.renderer.getContents()) {
      const selection = doc.getSelection();
      if (!selection?.rangeCount || selection.isCollapsed) continue;
      const range = selection.getRangeAt(0).cloneRange();
      if (!range.toString().trim()) continue;
      const selected = {
        type: "selected",
        cfi: view.getCFI(index, range),
        quote: range.toString(),
        rects: fragments(range),
        index,
        font,
        sourceHash,
        prefix: range.startContainer.textContent.slice(Math.max(0, range.startOffset - 80), range.startOffset),
        suffix: range.endContainer.textContent.slice(range.endOffset, range.endOffset + 80),
        provenance: "Tester selected a DOM range; no automatic stroke grouping or intent recognition",
      };
      selection.removeAllRanges();
      send(selected);
      return selected;
    }
    send({ type: "error", message: "First turn writing off, then long-press and select words on the page." });
  },
  async layout(action) {
    generation++;
    if (action === "bigger") font = Math.min(font + 8, 56);
    if (action === "smaller") font = Math.max(font - 8, 16);
    if (action === "narrow") view.style.width = "65%";
    if (action === "wide") view.style.width = "100%";
    if (action === "margins") view.renderer.setAttribute("margin", "84px");
    if (action === "normalMargins") view.renderer.setAttribute("margin", "28px");
    if (action === "scrolled") view.renderer.setAttribute("flow", "scrolled");
    if (action === "paginated") view.renderer.setAttribute("flow", "paginated");
    view.renderer.setStyles(`html{font-size:${font}px!important}body{font-family:Sample,Georgia,serif!important;line-height:1.6!important}`);
    await new Promise((resolve) => setTimeout(resolve, 180));
    if (focusCFI || groups[0]) await view.goTo(focusCFI || groups[0].cfi);
    await Promise.all(view.renderer.getContents().map(({ doc }) => doc.fonts.ready));
    await new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve)));
    measure(action);
  },
  async restoreFont(value) {
    font = value;
    await window.reflow.layout("restore-font");
  },
  async reset() {
    groups = [];
    focusCFI = null;
    font = 24;
    view.style.width = "100%";
    view.renderer.setAttribute("margin", "28px");
    view.renderer.setAttribute("flow", "paginated");
    await view.goTo(chapter);
    await window.reflow.layout("reset");
  },
  async go(direction) {
    await view[direction]();
    schedule(direction);
  },
  async scroll(distance) {
    await view.renderer.next(distance);
    schedule("finger-scroll");
  },
  async focus(cfi) {
    focusCFI = cfi;
    await view.goTo(cfi);
    schedule("focus-note");
  },
  async reload() {
    const target = focusCFI || groups[0]?.cfi || chapter;
    await view.goTo((chapter + 1) % view.book.sections.length);
    await view.goTo(target);
    schedule("chapter-reloaded");
  },
  inspect: () => ({ font, sourceHash, groups, generation, contents: view.renderer.getContents().map((item) => item.index) }),
};

if (new URL(location.href).searchParams.has("probe")) {
  window.reflowProbe = {
    selectSentence() {
      const { doc } = view.renderer.getContents()[0];
      const paragraph = doc.querySelector("p");
      const range = doc.createRange();
      range.setStart(paragraph, 0);
      let remaining = paragraph.textContent.indexOf(".") + 1;
      const walker = doc.createTreeWalker(paragraph, NodeFilter.SHOW_TEXT);
      for (let node = walker.nextNode(); node; node = walker.nextNode()) {
        if (remaining <= node.textContent.length) {
          range.setEnd(node, remaining);
          break;
        }
        remaining -= node.textContent.length;
      }
      const selection = doc.getSelection();
      selection.removeAllRanges();
      selection.addRange(range);
      return window.reflow.select();
    },
    selectOccurrence(occurrence = 1) {
      const { doc } = view.renderer.getContents()[0];
      const walker = doc.createTreeWalker(doc.body, NodeFilter.SHOW_TEXT);
      let found = 0;
      for (let node = walker.nextNode(); node; node = walker.nextNode()) {
        for (const match of node.textContent.matchAll(/useful/g)) {
          if (found++ !== occurrence) continue;
          const range = doc.createRange();
          range.setStart(node, match.index);
          range.setEnd(node, match.index + 6);
          const selection = doc.getSelection();
          selection.removeAllRanges();
          selection.addRange(range);
          return window.reflow.select();
        }
      }
      throw new Error("Probe occurrence was not found");
    },
    async sequence() {
      for (const action of ["bigger", "narrow", "wide", "smaller", "scrolled", "paginated"]) {
        await window.reflow.layout(action);
        await new Promise((resolve) => setTimeout(resolve, 450));
      }
      await window.reflow.reload();
      send({
        ...window.lastReflowMessage,
        type: "geometry",
        sequence: ++sequence,
        reason: "non-finite-progress-probe",
        location: { current: Number.NaN, total: Infinity },
      });
    },
  };
}

try {
  const response = await fetch("./reflow.epub");
  if (!response.ok) throw new Error(`EPUB request failed (${response.status})`);
  const bytes = await response.arrayBuffer();
  sourceHash = [...new Uint8Array(await crypto.subtle.digest("SHA-256", bytes))].map((x) => x.toString(16).padStart(2, "0")).join("");
  await view.open(new File([bytes], "reflow.epub", { type: "application/epub+zip" }));
  view.renderer.setAttribute("flow", "paginated");
  view.renderer.setAttribute("max-column-count", "1");
  view.renderer.setAttribute("max-inline-size", "1400px");
  view.renderer.setAttribute("margin", "28px");
  view.renderer.setAttribute("gap", "7%");
  view.renderer.setStyles("html{font-size:24px!important}body{font-family:Sample,Georgia,serif!important;line-height:1.6!important}");
  view.renderer.addEventListener("relocate", () => schedule("relocate"));
  view.renderer.addEventListener("scroll", () => schedule("scroll"));
  window.addEventListener("resize", () => {
    generation++;
    schedule("viewport-resized");
  });
  await view.goTo(chapter);
  problem.textContent = "";
  send({ type: "ready", sourceHash, chapter, userAgent: navigator.userAgent });
  schedule("ready");
} catch (error) {
  fail(error);
}
