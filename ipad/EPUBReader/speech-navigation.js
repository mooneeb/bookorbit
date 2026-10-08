export const previousSpeechStart = async (doc, start, maximum, getBlocks, extract, checkActive) => {
  let previous;
  let first;
  let visited = 0;
  for (const block of getBlocks(doc)) {
    if (++visited % 32 === 0) {
      await new Promise((resolve) => setTimeout(resolve, 0));
      checkActive();
    }
    if (block.comparePoint(start.startContainer, start.startOffset) < 0) break;
    let cursor = block.cloneRange();
    cursor.collapse(true);
    for (;;) {
      checkActive();
      const { parts, next } = extract(doc, cursor, maximum, block);
      if (parts.length) {
        const range = doc.createRange();
        range.setStart(parts[0].node, parts[0].offset);
        range.collapse(true);
        const text = parts.map((part) => part.node.nodeValue.slice(part.offset, part.offset + part.count)).join("");
        if (text.trim()) {
          first ??= range;
          if (range.comparePoint(start.startContainer, start.startOffset) <= 0) return previous ?? first;
          previous = range;
        }
      }
      if (!next || block.comparePoint(next.node, next.offset) !== 0 || (next.node === block.endContainer && next.offset === block.endOffset)) break;
      const following = doc.createRange();
      following.setStart(next.node, next.offset);
      following.collapse(true);
      if (following.compareBoundaryPoints(Range.START_TO_START, cursor) <= 0) throw new Error("The previous speech passage could not be located.");
      cursor = following;
      if (++visited % 32 === 0) {
        await new Promise((resolve) => setTimeout(resolve, 0));
        checkActive();
      }
    }
  }
  checkActive();
  return previous ?? first ?? start;
};
