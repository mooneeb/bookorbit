<script setup lang="ts">
import { computed, nextTick, ref, watch } from 'vue'
import { useDocumentState } from '@embedpdf/core/vue'
import { transformPosition, transformRect, transformSize, type Rotation } from '@embedpdf/models'
import { GlobalPointerProvider, PagePointerProvider, useInteractionManager } from '@embedpdf/plugin-interaction-manager/vue'
import { usePan } from '@embedpdf/plugin-pan/vue'
import { RenderLayer } from '@embedpdf/plugin-render/vue'
import { Rotate, useRotate } from '@embedpdf/plugin-rotate/vue'
import { Scroller } from '@embedpdf/plugin-scroll/vue'
import { SelectionLayer, useSelectionCapability } from '@embedpdf/plugin-selection/vue'
import { TilingLayer } from '@embedpdf/plugin-tiling/vue'
import { useViewportCapability } from '@embedpdf/plugin-viewport/vue'
import { ZoomGestureWrapper, useZoom } from '@embedpdf/plugin-zoom/vue'
import InkViewport from './InkViewport.prototype.vue'
import type { ProofManifest } from './types'

const props = defineProps<{ documentId: string; manifest: ProofManifest }>()
const state = useDocumentState(() => props.documentId)
const { state: zoomState, provides: zoom } = useZoom(() => props.documentId)
const { rotation, provides: rotate } = useRotate(() => props.documentId)
const { provides: interaction } = useInteractionManager(() => props.documentId)
const { provides: pan } = usePan(() => props.documentId)
const { provides: selection } = useSelectionCapability()
const { provides: viewport } = useViewportCapability()
const originalHint = ref(false)
const scale = computed(() => state.value?.scale ?? 1)
const inkTransform = computed(() => `matrix(${props.manifest.pdf.canvasToPage.join(' ')})`)
const svgWidth = computed(() => props.manifest.pdf.width * scale.value)
const svgHeight = computed(() => props.manifest.pdf.height * scale.value)
const page = computed(() => state.value?.document?.pages[0])
const pageSize = computed(() => page.value?.size ?? { width: props.manifest.pdf.width, height: props.manifest.pdf.height })
const effectiveRotation = computed(() => (((page.value?.rotation ?? 0) + rotation.value) % 4) as Rotation)
const rotatedPage = computed(() => transformSize(pageSize.value, effectiveRotation.value, 1))
const canvasBounds = computed(() => {
  const [a, b, c, d, e, f] = props.manifest.pdf.canvasToPage
  const { width, height } = props.manifest.pdf.nativeCanvas
  const points = (
    [
      [0, 0],
      [width, 0],
      [0, height],
      [width, height],
    ] as const
  ).map(([x, y]) => ({ x: a * x + c * y + e, y: b * x + d * y + f }))
  const x = Math.min(...points.map((point) => point.x))
  const y = Math.min(...points.map((point) => point.y))
  return transformRect(
    pageSize.value,
    {
      origin: { x, y },
      size: { width: Math.max(...points.map((point) => point.x)) - x, height: Math.max(...points.map((point) => point.y)) - y },
    },
    effectiveRotation.value,
    1,
  )
})
const margin = computed(() => ({
  left: Math.max(0, -canvasBounds.value.origin.x),
  top: Math.max(0, -canvasBounds.value.origin.y),
  right: Math.max(0, canvasBounds.value.origin.x + canvasBounds.value.size.width - rotatedPage.value.width),
  bottom: Math.max(0, canvasBounds.value.origin.y + canvasBounds.value.size.height - rotatedPage.value.height),
}))
const padding = computed(() => ({
  left: 12 + margin.value.left * scale.value,
  top: 12 + margin.value.top * scale.value,
  right: 12 + margin.value.right * scale.value,
  bottom: 12 + margin.value.bottom * scale.value,
}))

async function fit() {
  const metrics = viewport.value?.forDocument(props.documentId).getMetrics()
  if (!page.value || !metrics?.clientWidth || !metrics.clientHeight) return
  zoom.value?.requestZoom(
    Math.max(
      0.25,
      Math.min(
        4,
        (metrics.clientWidth - 24) / (rotatedPage.value.width + margin.value.left + margin.value.right),
        (metrics.clientHeight - 24) / (rotatedPage.value.height + margin.value.top + margin.value.bottom),
      ),
    ),
  )
}

function findMarginInk() {
  const [a, b, c, d, e, f] = props.manifest.pdf.canvasToPage
  const point = transformPosition(pageSize.value, { x: a * 590 + c * 42 + e, y: b * 590 + d * 42 + f }, effectiveRotation.value, scale.value)
  viewport.value?.forDocument(props.documentId).scrollTo({ x: point.x, y: point.y, alignX: 50, alignY: 50, behavior: 'instant' })
}

watch(page, () => void nextTick(fit))

async function act(action: string) {
  if (action === 'fit') await fit()
  if (action === '2x') zoom.value?.requestZoom(2)
  if (action === '4x') zoom.value?.requestZoom(4)
  if (action === 'rotate') rotate.value?.rotateForward()
  if (action === 'selection') interaction.value?.activate('pointerMode')
  if (action === 'margin') findMarginInk()
  if (action === 'original') originalHint.value = true
  if (action === 'reset-rotation') {
    rotate.value?.setRotation(0)
    await fit()
  }
  await new Promise<void>((resolve) => requestAnimationFrame(() => requestAnimationFrame(() => resolve())))
}

async function twoTimes() {
  await act('2x')
}
async function fourTimes() {
  await act('4x')
}
async function rotateClockwise() {
  await act('rotate')
}
function selectText() {
  interaction.value?.activate('pointerMode')
}
function panPage() {
  pan.value?.enablePan()
}

function evidence() {
  return {
    engine: 'Installed patched EmbedPDF/PDFium 2.15.1',
    zoom: zoomState.value.currentZoomLevel,
    rotation: rotation.value,
    scale: scale.value,
    interactionMode: interaction.value?.getActiveMode(),
    document: state.value?.document,
    canvasToPage: props.manifest.pdf.canvasToPage,
    originalSha256: props.manifest.pdf.originalSha256,
    sourceSha256: props.manifest.pdf.sourceSha256,
    previewSha256: props.manifest.pdf.previewSha256,
    canvasBounds: canvasBounds.value,
    padding: padding.value,
  }
}
async function selectionText() {
  return (await selection.value?.forDocument(props.documentId).getSelectedText().toPromise()) ?? []
}
defineExpose({ act, evidence, selectionText })
</script>

<template>
  <div>
    <div class="mb-2 flex flex-wrap items-center gap-2">
      <button class="rounded border border-border px-3 py-2 text-sm" @click="fit">Fit page and ink</button>
      <button class="rounded border border-border px-3 py-2 text-sm" @click="twoTimes">2x</button>
      <button class="rounded border border-border px-3 py-2 text-sm" @click="fourTimes">4x</button>
      <button class="rounded border border-border px-3 py-2 text-sm" @click="rotateClockwise">Rotate clockwise</button>
      <button class="rounded border border-border px-3 py-2 text-sm" @click="selectText">Select text</button>
      <button class="rounded border border-border px-3 py-2 text-sm" @click="panPage">Pan page</button>
      <button class="rounded border border-border px-3 py-2 text-sm" @click="findMarginInk">Find handwritten useful</button>
      <span class="text-sm text-muted-foreground">{{ Math.round(zoomState.currentZoomLevel * 100) }}%, added rotation {{ rotation * 90 }}°</span>
    </div>
    <div class="relative h-[440px] overflow-hidden rounded-lg border border-border sm:h-[540px]" data-proof-pdf>
      <GlobalPointerProvider :document-id="documentId">
        <InkViewport :document-id="documentId" :page-width="rotatedPage.width * scale" :padding="padding" @ready="fit">
          <ZoomGestureWrapper :document-id="documentId" class="ml-0!">
            <Scroller :document-id="documentId">
              <template #default="{ page }">
                <Rotate :document-id="documentId" :page-index="page.pageIndex" :data-page-index="page.pageIndex" class="bg-background shadow-md">
                  <PagePointerProvider :document-id="documentId" :page-index="page.pageIndex">
                    <RenderLayer :document-id="documentId" :page-index="page.pageIndex" :scale="0.5" class="pointer-events-none" />
                    <TilingLayer :document-id="documentId" :page-index="page.pageIndex" class="pointer-events-none" />
                    <SelectionLayer :document-id="documentId" :page-index="page.pageIndex" />
                    <svg
                      :width="svgWidth"
                      :height="svgHeight"
                      viewBox="0 0 624 468"
                      class="pointer-events-none absolute left-0 top-0 overflow-visible"
                      data-proof-ink
                    >
                      <image href="/proof-input/pdf-ink.png" width="640" height="480" :transform="inkTransform" />
                    </svg>
                  </PagePointerProvider>
                </Rotate>
              </template>
            </Scroller>
          </ZoomGestureWrapper>
        </InkViewport>
      </GlobalPointerProvider>
    </div>
    <details class="mt-3 rounded border border-border p-3">
      <summary class="cursor-pointer text-sm font-medium">Compare with the saved iPad reference</summary>
      <p class="my-2 text-sm text-muted-foreground">
        This is the original iPad view. Compare the same marks and printed words. The reader above uses the actual PDF.
      </p>
      <div class="relative">
        <img src="/proof-input/pdf-reference.png" alt="Original PDF as rendered on iPad" class="w-full" />
        <img
          src="/proof-input/pdf-ink.png"
          alt="Same original iPad handwriting on the reference"
          class="pointer-events-none absolute inset-0 w-full"
        />
      </div>
    </details>
    <p v-if="originalHint" class="mt-3 rounded border border-border p-3 text-sm">
      On iPad: All walkthroughs → {{ manifest.pdf.nativeWalkthrough }}. Open its existing saved drawing, erase a small mark, then Undo. Do not restart
      or delete that walkthrough.
    </p>
  </div>
</template>
