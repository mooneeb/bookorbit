<script setup lang="ts">
import { computed, onBeforeUnmount, onMounted, ref } from 'vue'
import type { ProofManifest } from './types'

interface FoliateContent {
  doc: Document
  index: number
}
interface FoliateView extends HTMLElement {
  open: (file: File) => Promise<void>
  close: () => void
  goTo: (target: string | number) => Promise<unknown>
  prev: () => Promise<unknown>
  next: () => Promise<unknown>
  addAnnotation: (annotation: { value: string }) => Promise<unknown>
  resolveCFI: (cfi: string) => { index: number; anchor: (doc: Document) => Range }
  renderer: HTMLElement & { render: (...args: unknown[]) => void; setStyles: (css: string) => void; getContents: () => FoliateContent[] }
}

const props = defineProps<{ manifest: ProofManifest; typed?: boolean }>()
const emit = defineEmits<{ ready: [value: boolean]; change: [message: string] }>()
const host = ref<HTMLElement | null>(null)
const noteOpen = ref(false)
const ready = ref(false)
const problem = ref('')
const font = ref(24)
const narrow = ref(false)
const selectedQuote = ref('')
const fragments = ref(0)
const saved = ref('This observation is worth returning to.')
const draft = ref(saved.value)
const noteStatus = ref('')
const originalHint = ref(false)
const bodyLabel = computed(() => (props.typed ? 'Typed note' : 'Handwritten note'))
let view: FoliateView | null = null
let stopped = false

function report() {
  emit('change', `${font.value}px text, ${narrow.value ? 'narrow' : 'normal'} page. ${noteOpen.value ? 'Note open.' : 'Note closed.'}`)
}

function measure() {
  if (!view?.renderer) return
  const target = view.resolveCFI(props.manifest.epub.cfi)
  const content = view.renderer.getContents().find((item) => item.index === target.index)
  if (!content) return
  const range = target.anchor(content.doc)
  selectedQuote.value = range.toString()
  fragments.value = Array.from(range.getClientRects()).filter((rect) => rect.width > 0 && rect.height > 0).length
  if (selectedQuote.value !== props.manifest.epub.quote)
    throw new Error('The selected words do not match the saved note. This sample will not move it to other text.')
}

function drawHighlight(event: Event) {
  const detail = (event as CustomEvent).detail
  if (detail.annotation?.value !== props.manifest.epub.cfi) return
  detail.draw((rects: DOMRectList) => {
    const group = document.createElementNS('http://www.w3.org/2000/svg', 'g')
    group.setAttribute('fill', getComputedStyle(document.documentElement).getPropertyValue('--primary').trim())
    group.setAttribute('opacity', '0.25')
    for (const rect of Array.from(rects)) {
      const node = document.createElementNS('http://www.w3.org/2000/svg', 'rect')
      for (const [name, value] of Object.entries({ x: rect.left, y: rect.top, width: rect.width, height: rect.height }))
        node.setAttribute(name, String(value))
      group.append(node)
    }
    return group
  })
}

function openNote() {
  noteOpen.value = true
  report()
}

function closeNote() {
  noteOpen.value = false
  report()
}

function saveNote() {
  saved.value = draft.value
  noteStatus.value = 'Saved in this sample. No BookOrbit data was changed.'
}

async function settle() {
  if (!view) return
  await Promise.all(view.renderer.getContents().map(({ doc }) => doc.fonts.ready))
  await new Promise<void>((resolve) => requestAnimationFrame(() => requestAnimationFrame(() => resolve())))
  measure()
  await view.addAnnotation({ value: props.manifest.epub.cfi })
  report()
}

async function act(action: string) {
  if (!ready.value || !view) throw new Error('Wait for the sample book to open.')
  if (action === 'open') openNote()
  if (action === 'close') closeNote()
  if (action === 'original') originalHint.value = true
  if (['larger', 'narrow', 'normal'].includes(action)) {
    if (action === 'larger') font.value = 40
    if (action === 'narrow') narrow.value = true
    if (action === 'normal') {
      font.value = 24
      narrow.value = false
    }
    view.style.width = narrow.value ? 'min(100%, 330px)' : '100%'
    view.renderer.setStyles(`html{font-size:${font.value}px!important}body{line-height:1.6!important}`)
    await new Promise((resolve) => setTimeout(resolve, 120))
    await view.goTo(props.manifest.epub.cfi)
    await settle()
  }
}

async function previousPage() {
  await view?.prev()
  report()
}
async function nextPage() {
  await view?.next()
  report()
}
async function returnToNote() {
  await view?.goTo(props.manifest.epub.cfi)
  await settle()
  openNote()
}

function evidence() {
  return {
    engine: 'BookOrbit vendored Foliate',
    quote: selectedQuote.value,
    expectedQuote: props.manifest.epub.quote,
    fragments: fragments.value,
    font: font.value,
    narrow: narrow.value,
    noteOpen: noteOpen.value,
    savedText: props.typed ? saved.value : undefined,
    draftText: props.typed ? draft.value : undefined,
    sourceSha256: props.manifest.epub.sourceSha256,
    originalSha256: props.manifest.epub.originalSha256,
    previewSha256: props.manifest.epub.previewSha256,
    association: props.manifest.epub.association,
  }
}

onMounted(async () => {
  try {
    if (!customElements.get('foliate-view')) {
      await new Promise<void>((resolve, reject) => {
        const script = document.createElement('script')
        script.type = 'module'
        script.src = '/assets/foliate/view.js'
        script.onload = () => resolve()
        script.onerror = () => reject(new Error('The local EPUB reader module could not be loaded.'))
        document.head.append(script)
      })
    }
    await customElements.whenDefined('foliate-view')
    if (stopped) return
    view = document.createElement('foliate-view') as FoliateView
    view.style.cssText = 'display:block;width:100%;height:100%;margin:auto;'
    view.addEventListener('draw-annotation', drawHighlight)
    view.addEventListener('show-annotation', (event: Event) => {
      if ((event as CustomEvent).detail.value === props.manifest.epub.cfi) openNote()
    })
    host.value?.append(view)
    const response = await fetch('/proof-input/book.epub')
    await view.open(new File([await response.blob()], 'reading-sample.epub', { type: 'application/epub+zip' }))
    if (stopped) {
      view.close()
      return
    }
    const render = view.renderer.render.bind(view.renderer)
    // A queued resize can arrive before the iframe body is ready or after teardown.
    view.renderer.render = (...args: unknown[]) => {
      if (!stopped && view?.renderer.getContents().every((content) => content.doc?.body)) render(...args)
    }
    view.renderer.setAttribute('max-column-count', '1')
    view.renderer.setAttribute('margin', '24px')
    view.renderer.setStyles('html{font-size:24px!important}body{line-height:1.6!important}')
    await view.goTo(props.manifest.epub.cfi)
    await settle()
    if (stopped) return
    ready.value = true
    emit('ready', true)
  } catch (error) {
    problem.value = error instanceof Error ? error.message : String(error)
    emit('change', 'The EPUB could not be opened. Please report the visible message.')
  }
})

onBeforeUnmount(() => {
  stopped = true
  view?.close()
  view?.remove()
})
defineExpose({ act, evidence })
</script>

<template>
  <div>
    <p v-if="problem" role="alert" class="rounded-lg border border-destructive p-4 text-destructive">{{ problem }}</p>
    <p v-else-if="!ready" role="status" class="p-4 text-muted-foreground">Opening this walkthrough's EPUB sample...</p>
    <div class="mb-2 flex flex-wrap gap-2">
      <button :disabled="!ready" class="rounded border border-border px-3 py-2 text-sm disabled:opacity-40" @click="previousPage">
        Previous page
      </button>
      <button :disabled="!ready" class="rounded border border-border px-3 py-2 text-sm disabled:opacity-40" @click="nextPage">Next page</button>
      <button :disabled="!ready" class="rounded border border-border px-3 py-2 text-sm disabled:opacity-40" @click="returnToNote">
        Find the noted words
      </button>
    </div>
    <div ref="host" class="h-[400px] overflow-hidden rounded-lg border border-border bg-card text-card-foreground sm:h-[480px]" data-proof-epub />
    <section
      v-if="noteOpen"
      aria-label="Linked reading note"
      class="fixed bottom-4 left-4 right-4 z-50 max-h-[70vh] overflow-auto rounded-lg border border-primary bg-card p-4 text-card-foreground shadow-lg sm:bottom-auto sm:left-auto sm:right-6 sm:top-12 sm:w-96"
    >
      <div class="flex items-center justify-between gap-3">
        <h3 class="font-semibold">{{ bodyLabel }}</h3>
        <button class="rounded border border-border px-3 py-2 text-sm" @click="closeNote">Close note</button>
      </div>
      <p class="my-3 text-sm">
        Selected words: <strong>{{ manifest.epub.quote }}</strong>
      </p>
      <template v-if="typed">
        <label for="sample-note" class="mb-2 block text-sm">Your sample note</label>
        <textarea id="sample-note" v-model="draft" class="min-h-28 w-full rounded border border-input bg-background p-3 text-foreground" />
        <button class="mt-2 rounded bg-primary px-3 py-2 text-primary-foreground" @click="saveNote">Save this sample note</button>
        <p aria-live="polite" class="mt-2 text-sm text-muted-foreground">{{ noteStatus }}</p>
      </template>
      <img
        v-else
        src="/proof-input/epub-note.png"
        alt="Saved handwriting rendered from the original iPad drawing"
        class="max-h-80 w-full object-contain"
      />
    </section>
    <p v-if="originalHint" class="mt-3 rounded border border-border p-3 text-sm">
      On iPad: All walkthroughs → {{ manifest.epub.nativeWalkthrough }}. Open its saved drawing, erase a small mark, then Undo. Keep this check
      pending until you try it on the iPad.
    </p>
  </div>
</template>
