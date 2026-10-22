<script setup lang="ts">
import { computed, ref } from 'vue'
import { useDocumentState } from '@embedpdf/core/vue'
import { GlobalPointerProvider, PagePointerProvider, useInteractionManager } from '@embedpdf/plugin-interaction-manager/vue'
import { usePan } from '@embedpdf/plugin-pan/vue'
import { RenderLayer } from '@embedpdf/plugin-render/vue'
import { Rotate, useRotate } from '@embedpdf/plugin-rotate/vue'
import { Scroller } from '@embedpdf/plugin-scroll/vue'
import { SelectionLayer, useSelectionCapability } from '@embedpdf/plugin-selection/vue'
import { TilingLayer } from '@embedpdf/plugin-tiling/vue'
import { Viewport } from '@embedpdf/plugin-viewport/vue'
import { ZoomGestureWrapper, ZoomMode, useZoom } from '@embedpdf/plugin-zoom/vue'
import type { ProofManifest } from './types'

const props = defineProps<{ documentId: string; manifest: ProofManifest }>()
const state = useDocumentState(() => props.documentId)
const { state: zoomState, provides: zoom } = useZoom(() => props.documentId)
const { rotation, provides: rotate } = useRotate(() => props.documentId)
const { provides: interaction } = useInteractionManager(() => props.documentId)
const { provides: pan } = usePan(() => props.documentId)
const { provides: selection } = useSelectionCapability()
const originalHint = ref(false)
const scale = computed(() => state.value?.scale ?? 1)
const inkTransform = computed(() => `matrix(${props.manifest.pdf.canvasToPage.join(' ')})`)
const svgWidth = computed(() => props.manifest.pdf.width * scale.value)
const svgHeight = computed(() => props.manifest.pdf.height * scale.value)

async function act(action: string) {
  if (action === 'fit') zoom.value?.requestZoom(ZoomMode.FitPage)
  if (action === '2x') zoom.value?.requestZoom(2)
  if (action === '4x') zoom.value?.requestZoom(4)
  if (action === 'rotate') rotate.value?.rotateForward()
  if (action === 'selection') interaction.value?.activate('pointerMode')
  if (action === 'original') originalHint.value = true
  if (action === 'reset-rotation') {
    rotate.value?.setRotation(0)
    zoom.value?.requestZoom(ZoomMode.FitPage)
  }
  await new Promise<void>((resolve) => requestAnimationFrame(() => requestAnimationFrame(() => resolve())))
}

async function fit() {
  await act('fit')
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
      <button class="rounded border border-border px-3 py-2 text-sm" @click="fit">Fit</button>
      <button class="rounded border border-border px-3 py-2 text-sm" @click="twoTimes">2x</button>
      <button class="rounded border border-border px-3 py-2 text-sm" @click="fourTimes">4x</button>
      <button class="rounded border border-border px-3 py-2 text-sm" @click="rotateClockwise">Rotate clockwise</button>
      <button class="rounded border border-border px-3 py-2 text-sm" @click="selectText">Select text</button>
      <button class="rounded border border-border px-3 py-2 text-sm" @click="panPage">Pan page</button>
      <span class="text-sm text-muted-foreground">{{ Math.round(zoomState.currentZoomLevel * 100) }}%, added rotation {{ rotation * 90 }}°</span>
    </div>
    <div class="relative h-[440px] overflow-hidden rounded-lg border border-border sm:h-[540px]" data-proof-pdf>
      <GlobalPointerProvider :document-id="documentId">
        <Viewport :document-id="documentId" class="absolute inset-0 bg-muted/40">
          <ZoomGestureWrapper :document-id="documentId">
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
        </Viewport>
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
