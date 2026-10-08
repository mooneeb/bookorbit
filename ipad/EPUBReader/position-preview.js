import { getBlocks } from "../foliate/tts.js";

export const describePosition = async (view, publication, target, isCurrent) => {
  if (!publication || typeof target !== "string" || target.length > 8192 || !isCurrent()) throw new Error("The saved passage is unavailable.");
  const legacy = /^tts:(\d+):(\d+)$/.exec(target);
  const resolved = legacy ? { index: Number(legacy[1]) } : await view.resolveNavigation(target);
  if (!resolved || !Number.isInteger(resolved.index) || !publication.sections[resolved.index]) throw new Error("The saved passage is unavailable.");
  const doc = await publication.sections[resolved.index].createDocument();
  if (!isCurrent()) throw new Error("The reader closed.");
  let anchor = resolved.anchor?.(doc);
  if (legacy) {
    let index = 0;
    for (const range of getBlocks(doc)) {
      if (index++ === Number(legacy[2])) {
        anchor = range;
        break;
      }
    }
    if (!anchor) throw new Error("The saved spoken block is unavailable.");
  }
  const root = doc.body ?? doc.documentElement;
  const walker = doc.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
    acceptNode: (node) => (node.parentElement?.closest("script,style,noscript") ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_ACCEPT),
  });
  const start = anchor?.startContainer ?? anchor ?? root;
  walker.currentNode = start;
  let node = start.nodeType === Node.TEXT_NODE ? start : walker.nextNode();
  let offset = anchor?.startContainer?.nodeType === Node.TEXT_NODE ? anchor.startOffset : 0;
  let text = "";
  for (let scanned = 0; node && scanned < 256 && text.length < 240; scanned++) {
    text += node.nodeValue.slice(offset, offset + 240 - text.length);
    offset = 0;
    node = walker.nextNode();
  }
  return {
    chapterIndex: resolved.index,
    text: text.replace(/\s+/gu, " ").trim().slice(0, 240),
  };
};
