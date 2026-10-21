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
let includeLineBindings = false;
let includeCharacterBindings = false;
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

function selectedLines(range, index) {
  if (range.toString().length > 500) throw new Error("Select at most 500 characters for this experiment.");
  const doc = range.startContainer.ownerDocument;
  const root = range.commonAncestorContainer;
  const nodes = [];
  if (root.nodeType === Node.TEXT_NODE) nodes.push(root);
  else {
    const walker = doc.createTreeWalker(root, NodeFilter.SHOW_TEXT);
    for (let node = walker.nextNode(); node; node = walker.nextNode()) {
      if (range.intersectsNode(node)) nodes.push(node);
    }
  }
  const lines = [];
  for (const node of nodes) {
    const start = node === range.startContainer ? range.startOffset : 0;
    const end = node === range.endContainer ? range.endOffset : node.textContent.length;
    for (let offset = start; offset < end;) {
      const length = String.fromCodePoint(node.textContent.codePointAt(offset)).length;
      const character = doc.createRange();
      character.setStart(node, offset);
      character.setEnd(node, Math.min(offset + length, end));
      offset += length;
      const rect = fragments(character).find((r) => r.width > 0);
      const last = lines.at(-1);
      if (!rect) {
        if (last) last.range.setEnd(character.endContainer, character.endOffset);
        continue;
      }
      if (last && Math.abs(last.rect.y + last.rect.height / 2 - rect.y - rect.height / 2) < Math.max(last.rect.height, rect.height) * 0.4) {
        last.range.setEnd(character.endContainer, character.endOffset);
        const right = Math.max(last.rect.x + last.rect.width, rect.x + rect.width);
        const bottom = Math.max(last.rect.y + last.rect.height, rect.y + rect.height);
        last.rect.x = Math.min(last.rect.x, rect.x);
        last.rect.y = Math.min(last.rect.y, rect.y);
        last.rect.width = right - last.rect.x;
        last.rect.height = bottom - last.rect.y;
      } else lines.push({ range: character.cloneRange(), rect });
    }
  }
  if (lines.length > 12) throw new Error("This experiment supports at most twelve lines.");
  return lines.map((line) => ({ cfi: view.getCFI(index, line.range), quote: line.range.toString(), rect: line.rect }));
}

function selectedCharacters(range, index) {
  if (range.toString().length > 160) throw new Error("For this gap check, select only the first sentence.");
  const doc = range.startContainer.ownerDocument;
  const root = range.commonAncestorContainer;
  const nodes = [];
  if (root.nodeType === Node.TEXT_NODE) nodes.push(root);
  else {
    const walker = doc.createTreeWalker(root, NodeFilter.SHOW_TEXT);
    for (let node = walker.nextNode(); node; node = walker.nextNode()) {
      if (range.intersectsNode(node)) nodes.push(node);
    }
  }
  const characters = [];
  for (const node of nodes) {
    const start = node === range.startContainer ? range.startOffset : 0;
    const end = node === range.endContainer ? range.endOffset : node.textContent.length;
    for (let offset = start; offset < end;) {
      const length = String.fromCodePoint(node.textContent.codePointAt(offset)).length;
      const unit = doc.createRange();
      unit.setStart(node, offset);
      unit.setEnd(node, Math.min(offset + length, end));
      offset += length;
      const rect = fragments(unit).find((r) => r.width > 0);
      if (rect) characters.push({ cfi: view.getCFI(index, unit), quote: unit.toString(), rect, collapsed: false });
      else if (!unit.toString().trim() && characters.length) {
        const previous = characters.at(-1).rect;
        characters.push({
          cfi: view.getCFI(index, unit),
          quote: unit.toString(),
          collapsed: true,
          rect: { x: previous.x + previous.width / 2 - 0.5, y: previous.y, width: 1, height: previous.height },
        });
      }
    }
  }
  return characters;
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
      return {
        id: group.id,
        status: visible.length ? "resolved" : "offscreen",
        quote: range.toString(),
        rects,
        visible,
        index: locator.index,
        ...(includeLineBindings ? { lines: selectedLines(range, locator.index) } : {}),
        ...(includeCharacterBindings ? { characters: selectedCharacters(range, locator.index) } : {}),
      };
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
  setGroups(value, activeCFI, lineBindings = false, characterBindings = false) {
    groups = value;
    focusCFI = activeCFI;
    includeLineBindings = lineBindings;
    includeCharacterBindings = characterBindings;
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
    if (action === "gap-wrap") view.style.width = "min(65%, 560px)";
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
