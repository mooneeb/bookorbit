import { ref } from 'vue'
import type { TtsPosition } from '@bookorbit/types'
import * as ttsApi from '../api/tts.api'

interface FoliateContent {
  index: number
  doc?: Document
  overlayer?: {
    add(key: string, range: Range, draw: (rects: DOMRectList, opts: unknown) => Element, options: unknown): void
    remove(key: string): void
  }
}

interface FoliateRenderer extends EventTarget {
  getContents?: () => FoliateContent[]
  scrollToAnchor?: (anchor: Range, select?: boolean) => Promise<void>
}

interface FoliateViewElement extends HTMLElement {
  renderer?: FoliateRenderer
  resolveCFI?: (cfi: string) => { index?: number; anchor?: (doc: Document) => Range } | undefined
  getCFI?: (index: number, range: Range) => string
}

const TTS_HIGHLIGHT_KEY = '__tts_highlight__'
const TTS_HIGHLIGHT_COLOR = '#4FC3F7'

// Block-level tags, kept identical to Foliate's TTS block segmentation
// (public/assets/foliate/tts.js) and the server extractor
// (tts-text-extractor.service.ts htmlToBlocks). This is what guarantees that
// audio block index N (server) lines up with highlighted paragraph N (client).
const BLOCK_TAGS = new Set([
  'article',
  'aside',
  'audio',
  'blockquote',
  'caption',
  'details',
  'dialog',
  'div',
  'dl',
  'dt',
  'dd',
  'figure',
  'footer',
  'form',
  'figcaption',
  'h1',
  'h2',
  'h3',
  'h4',
  'h5',
  'h6',
  'header',
  'hgroup',
  'hr',
  'li',
  'main',
  'math',
  'nav',
  'ol',
  'p',
  'pre',
  'section',
  'tr',
])

const foliateReady = ref(false)
let rendererRef: FoliateRenderer | null = null
let foliateViewRef: FoliateViewElement | null = null
let chapterDoc: Document | null = null
let chapterBlockRanges: Range[] = []
let cachedVisibleRange: Range | null = null
let relocateCleanup: (() => void) | null = null

function createSvgElement(tag: string): SVGElement {
  return document.createElementNS('http://www.w3.org/2000/svg', tag)
}

function drawHighlight(rects: DOMRectList, options?: { color?: string }): Element {
  const g = createSvgElement('g')
  g.setAttribute('fill', options?.color ?? 'red')
  ;(g as SVGGElement).style.opacity = 'var(--overlayer-highlight-opacity, .3)'
  ;(g as SVGGElement).style.mixBlendMode = 'var(--overlayer-highlight-blend-mode, normal)'
  for (const { left, top, height, width } of rects) {
    const rect = createSvgElement('rect')
    rect.setAttribute('x', String(left))
    rect.setAttribute('y', String(top))
    rect.setAttribute('height', String(height))
    rect.setAttribute('width', String(width))
    g.append(rect)
  }
  return g
}

function rangeText(range: Range): string {
  return range.toString().trim()
}

// Mirror of Foliate's getBlocks() (public/assets/foliate/tts.js): one range per
// block-level element's content, in document order, skipping empty blocks.
function collectBlockRanges(doc: Document): Range[] {
  const body = doc.body
  if (!body) return []
  const ranges: Range[] = []
  let last: Range | null = null
  const walker = doc.createTreeWalker(body, NodeFilter.SHOW_ELEMENT)
  for (let node = walker.nextNode(); node; node = walker.nextNode()) {
    const name = (node as Element).tagName.toLowerCase()
    if (!BLOCK_TAGS.has(name)) continue
    if (last) {
      last.setEndBefore(node)
      if (rangeText(last)) ranges.push(last)
    }
    last = doc.createRange()
    last.setStart(node, 0)
  }
  if (!last) {
    last = doc.createRange()
    last.setStart(body.firstChild ?? body, 0)
  }
  last.setEndAfter(body.lastChild ?? body)
  if (rangeText(last)) ranges.push(last)
  return ranges
}

function getContentForRange(range: Range): FoliateContent | null {
  const contents = rendererRef?.getContents?.()
  if (!contents?.length) return null
  const rangeDoc = range.commonAncestorContainer.ownerDocument
  return contents.find((content) => content.doc === rangeDoc) ?? contents[0] ?? null
}

function applyHighlight(range: Range) {
  try {
    const content = getContentForRange(range)
    const overlayer = content?.overlayer ?? rendererRef?.getContents?.()[0]?.overlayer
    if (!overlayer) return
    const ctor = overlayer.constructor as { highlight?: (rects: DOMRectList, options?: { color?: string }) => Element } | undefined
    const draw = ctor?.highlight ?? drawHighlight
    overlayer.remove(TTS_HIGHLIGHT_KEY)
    overlayer.add(TTS_HIGHLIGHT_KEY, range, draw as (rects: DOMRectList, opts: unknown) => Element, {
      color: TTS_HIGHLIGHT_COLOR,
    })
  } catch {
    // Overlayer may not be attached yet on the very first paint; safe to ignore.
  }
}

function clearHighlight() {
  try {
    const contents = rendererRef?.getContents?.() ?? []
    for (const content of contents) content.overlayer?.remove(TTS_HIGHLIGHT_KEY)
  } catch {
    // Ignore - overlayer may have been torn down already.
  }
}

function scrollRangeIntoView(range: Range) {
  if (!rendererRef) return
  try {
    void rendererRef.scrollToAnchor?.(range.cloneRange(), false)
  } catch {
    // Range can become stale while a chapter is being redrawn; ignore.
  }
}

export function useFoliateTts() {
  function setFoliateSource(doc: Document, viewEl: HTMLElement) {
    foliateReady.value = false
    chapterBlockRanges = []
    cachedVisibleRange = null

    relocateCleanup?.()
    const onRelocate = (evt: Event) => {
      const range = (evt as CustomEvent).detail?.range as Range | undefined
      if (range) cachedVisibleRange = range
    }
    viewEl.addEventListener('relocate', onRelocate)
    relocateCleanup = () => viewEl.removeEventListener('relocate', onRelocate)

    const foliateView = viewEl as FoliateViewElement
    foliateViewRef = foliateView
    rendererRef = foliateView.renderer ?? null
    chapterDoc = doc
    chapterBlockRanges = collectBlockRanges(doc)

    // Toggle ready on a later tick so per-chapter watchers observe a real
    // false -> true transition and re-run the highlight sync after each load.
    void Promise.resolve().then(() => {
      foliateReady.value = true
    })
  }

  function clearFoliateSource() {
    clearHighlight()
    relocateCleanup?.()
    relocateCleanup = null
    rendererRef = null
    foliateViewRef = null
    chapterDoc = null
    chapterBlockRanges = []
    cachedVisibleRange = null
    foliateReady.value = false
  }

  function getVisibleRange(): Range | null {
    return cachedVisibleRange
  }

  // Find the paragraph/block index that contains (or starts at) a range. Uses
  // the same boundary comparison Foliate's TTS.from() uses to locate a block.
  function getBlockIndexForRange(range: Range | null): number {
    if (!range || chapterBlockRanges.length === 0) return -1
    const rangeDoc = range.startContainer?.ownerDocument ?? range.commonAncestorContainer?.ownerDocument
    if (chapterDoc && rangeDoc && rangeDoc !== chapterDoc) return -1
    try {
      for (let i = 0; i < chapterBlockRanges.length; i++) {
        if (range.compareBoundaryPoints(Range.END_TO_START, chapterBlockRanges[i]!) <= 0) return i
      }
    } catch {
      return -1
    }
    return -1
  }

  function highlightBlock(blockIndex: number, scrollIntoView = true): boolean {
    const range = chapterBlockRanges[blockIndex]
    if (!range) return false
    applyHighlight(range)
    if (scrollIntoView) scrollRangeIntoView(range)
    return true
  }

  function showResumeHighlightFromBlock(chapterIndex: number, blockIndex: number, currentChapterIndex: number): boolean {
    if (chapterIndex !== currentChapterIndex) return false
    return highlightBlock(Math.max(0, blockIndex), false)
  }

  function showResumeHighlightFromCfi(cfi: string): boolean {
    if (!foliateViewRef || !cfi || /^tts:\d+:\d+$/.test(cfi)) return false
    const resolved = foliateViewRef.resolveCFI?.(cfi)
    const index = resolved?.index
    const anchor = resolved?.anchor
    if (typeof index !== 'number' || typeof anchor !== 'function') return false
    const content = rendererRef?.getContents?.()?.find((x) => x.index === index)
    if (!content?.doc || content.doc !== chapterDoc) return false
    try {
      const range = anchor(content.doc)
      const blockIndex = getBlockIndexForRange(range)
      if (blockIndex >= 0) return highlightBlock(blockIndex, false)
      applyHighlight(range)
      return true
    } catch {
      return false
    }
  }

  function getPositionForBlock(chapterIndex: number, blockIndex: number): TtsPosition | null {
    const content = rendererRef?.getContents?.()?.find((value) => value.index === chapterIndex && value.doc === chapterDoc)
    const block = chapterBlockRanges[blockIndex]
    if (!content || !block || !foliateViewRef?.getCFI) return null
    try {
      const point = block.cloneRange()
      point.collapse(true)
      const cfi = foliateViewRef.getCFI(chapterIndex, point)
      return cfi.startsWith('epubcfi(') ? { cfi, chapterIndex } : null
    } catch {
      return null
    }
  }

  function getSpeechStartFromCfi(cfi: string): { chapterIndex: number; blockIndex: number; segments: Array<{ text: string; cfi: string }> } | null {
    if (!foliateViewRef || !cfi.startsWith('epubcfi(')) return null
    try {
      const resolved = foliateViewRef.resolveCFI?.(cfi)
      const content = rendererRef?.getContents?.()?.find((value) => value.index === resolved?.index && value.doc === chapterDoc)
      if (!content?.doc || !resolved?.anchor || typeof resolved.index !== 'number') return null
      const point = resolved.anchor(content.doc)
      const blockIndex = getBlockIndexForRange(point)
      const block = chapterBlockRanges[blockIndex]
      if (!block) return null
      const remainder = block.cloneRange()
      remainder.setStart(point.startContainer, point.startOffset)
      const text = remainder.toString()
      if (!text.trim() || !foliateViewRef.getCFI) return null
      const segments: Array<{ text: string; cfi: string }> = []
      const graphemes = new Intl.Segmenter(undefined, { granularity: 'grapheme' }).segment(text)[Symbol.iterator]()
      let grapheme = graphemes.next()
      const walker = content.doc.createTreeWalker(content.doc.body, NodeFilter.SHOW_TEXT)
      let node = walker.nextNode()
      let nodeOffset = 0
      let consumed = 0
      for (let offset = 0; offset < text.length;) {
        let end = offset
        while (!grapheme.done && grapheme.value.index + grapheme.value.segment.length <= offset + 2048) {
          end = grapheme.value.index + grapheme.value.segment.length
          grapheme = graphemes.next()
        }
        if (end === offset) return null
        while (node) {
          if (!remainder.intersectsNode(node)) {
            node = walker.nextNode()
            continue
          }
          const startOffset = node === remainder.startContainer ? remainder.startOffset : 0
          const endOffset = node === remainder.endContainer ? remainder.endOffset : (node.textContent?.length ?? 0)
          if (consumed + endOffset - startOffset > offset) {
            nodeOffset = startOffset + offset - consumed
            break
          }
          consumed += endOffset - startOffset
          node = walker.nextNode()
        }
        if (!node) return null
        const anchor = content.doc.createRange()
        anchor.setStart(node, nodeOffset)
        anchor.collapse(true)
        const segmentCFI = offset === 0 ? cfi : foliateViewRef.getCFI(resolved.index, anchor)
        segments.push({ text: text.slice(offset, end), cfi: segmentCFI })
        offset = end
      }
      return { chapterIndex: resolved.index, blockIndex, segments }
    } catch {
      return null
    }
  }

  async function getServerTextBlocks(bookFileId: number, chapterIndex: number): Promise<string[]> {
    const chapterText = await ttsApi.getChapterText(bookFileId, chapterIndex)
    // Each server "sentence" entry is already one paragraph-level block, produced
    // by the same block segmentation Foliate uses. Keep them 1:1 so the audio
    // block index matches the highlighted paragraph index exactly.
    return chapterText.sentences.map((s) => s.text)
  }

  return {
    foliateReady,
    setFoliateSource,
    clearFoliateSource,
    getVisibleRange,
    getBlockIndexForRange,
    highlightBlock,
    showResumeHighlightFromCfi,
    showResumeHighlightFromBlock,
    clearHighlight,
    getServerTextBlocks,
    getPositionForBlock,
    getSpeechStartFromCfi,
  }
}
