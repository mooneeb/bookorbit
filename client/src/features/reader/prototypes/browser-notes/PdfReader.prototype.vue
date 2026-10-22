<script setup lang="ts">
import { ref } from 'vue'
import { EmbedPDF } from '@embedpdf/core/vue'
import { createPluginRegistration, type PluginRegistry } from '@embedpdf/core'
import { usePdfiumEngine } from '@embedpdf/engines/vue'
import pdfiumWasmUrl from '@embedpdf/pdfium/pdfium.wasm?url'
import { DocumentManagerPlugin, DocumentManagerPluginPackage } from '@embedpdf/plugin-document-manager/vue'
import { InteractionManagerPluginPackage } from '@embedpdf/plugin-interaction-manager/vue'
import { PanPluginPackage } from '@embedpdf/plugin-pan/vue'
import { RenderPluginPackage } from '@embedpdf/plugin-render/vue'
import { RotatePluginPackage } from '@embedpdf/plugin-rotate/vue'
import { ScrollPluginPackage } from '@embedpdf/plugin-scroll/vue'
import { SelectionPluginPackage } from '@embedpdf/plugin-selection/vue'
import { SpreadPluginPackage } from '@embedpdf/plugin-spread/vue'
import { TilingPluginPackage } from '@embedpdf/plugin-tiling/vue'
import { ViewportPluginPackage } from '@embedpdf/plugin-viewport/vue'
import { ZoomPluginPackage } from '@embedpdf/plugin-zoom/vue'
import PdfScene from './PdfScene.prototype.vue'
import type { ProofManifest, ReaderHandle } from './types'

defineProps<{ manifest: ProofManifest }>()
const emit = defineEmits<{ ready: [value: boolean]; change: [message: string] }>()
const scene = ref<ReaderHandle | null>(null)
const problem = ref('')
const { engine, error } = usePdfiumEngine({ wasmUrl: new URL(pdfiumWasmUrl, location.href).href, worker: true, fontFallback: null })
const plugins = [
  createPluginRegistration(DocumentManagerPluginPackage, { maxDocuments: 1 }),
  createPluginRegistration(ViewportPluginPackage, { viewportGap: 0 }),
  createPluginRegistration(ScrollPluginPackage, { defaultPageGap: 12, defaultBufferSize: 1 }),
  createPluginRegistration(InteractionManagerPluginPackage),
  createPluginRegistration(PanPluginPackage, { defaultMode: 'mobile' }),
  createPluginRegistration(ZoomPluginPackage, { defaultZoomLevel: 1, minZoom: 0.25, maxZoom: 4 }),
  createPluginRegistration(SpreadPluginPackage),
  createPluginRegistration(RotatePluginPackage),
  createPluginRegistration(RenderPluginPackage),
  createPluginRegistration(TilingPluginPackage, { tileSize: 768, overlapPx: 2.5, extraRings: 0 }),
  createPluginRegistration(SelectionPluginPackage, { marquee: { enabled: false } }),
]

async function initialized(registry: PluginRegistry) {
  try {
    await registry.pluginsReady()
    const response = await fetch('/proof-input/book.pdf')
    const manager = registry.getPlugin<DocumentManagerPlugin>(DocumentManagerPlugin.id)?.provides()
    if (!manager) throw new Error('The PDF document manager did not initialize.')
    const opened = await manager.openDocumentBuffer({ buffer: await response.arrayBuffer(), name: 'Saved iPad PDF' }).toPromise()
    await opened.task.toPromise()
    emit('ready', true)
    emit('change', 'PDF loaded with its original iPad handwriting. Text selection is enabled.')
  } catch (error) {
    problem.value = error instanceof Error ? error.message : String(error)
  }
}

async function act(action: string) {
  if (!scene.value) throw new Error('Wait for the PDF to open.')
  await scene.value.act(action)
  const value = scene.value.evidence()
  emit('change', `PDF zoom ${Math.round(Number(value.zoom) * 100)}%, added rotation ${Number(value.rotation) * 90}°. Ink stays visible.`)
}
function evidence() {
  return scene.value?.evidence() ?? { loading: true }
}
async function selectionText() {
  return (await scene.value?.selectionText?.()) ?? []
}
defineExpose({ act, evidence, selectionText })
</script>

<template>
  <p v-if="error || problem" role="alert" class="rounded border border-destructive p-4 text-destructive">{{ error?.message || problem }}</p>
  <EmbedPDF v-else-if="engine" :engine="engine" :plugins="plugins" :on-initialized="initialized">
    <template #default="{ pluginsReady, activeDocumentId }">
      <PdfScene v-if="pluginsReady && activeDocumentId" ref="scene" :document-id="activeDocumentId" :manifest="manifest" />
      <p v-else role="status" class="p-4">Opening this walkthrough's PDF...</p>
    </template>
  </EmbedPDF>
  <p v-else role="status" class="p-4">Starting the PDF reader...</p>
</template>
