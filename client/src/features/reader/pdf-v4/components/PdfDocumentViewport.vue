<script setup lang="ts">
import { AnnotationLayer } from '@embedpdf/plugin-annotation/vue'
import { GlobalPointerProvider, PagePointerProvider } from '@embedpdf/plugin-interaction-manager/vue'
import { RenderLayer } from '@embedpdf/plugin-render/vue'
import { Rotate } from '@embedpdf/plugin-rotate/vue'
import { Scroller } from '@embedpdf/plugin-scroll/vue'
import { SearchLayer } from '@embedpdf/plugin-search/vue'
import { SelectionLayer } from '@embedpdf/plugin-selection/vue'
import { TilingLayer } from '@embedpdf/plugin-tiling/vue'
import { Viewport } from '@embedpdf/plugin-viewport/vue'
import { ZoomGestureWrapper } from '@embedpdf/plugin-zoom/vue'
import type { AnnotationItem } from '@bookorbit/types'
import SourcePdfInkLayer from './SourcePdfInkLayer.vue'

defineProps<{ documentId: string; sourceInk?: AnnotationItem[]; selectedInkId?: number | null }>()
const emit = defineEmits<{ selectInk: [item: AnnotationItem]; contextInk: [item: AnnotationItem, event: MouseEvent] }>()
function handleSelectInk(item: AnnotationItem) {
  emit('selectInk', item)
}
function handleContextInk(item: AnnotationItem, event: MouseEvent) {
  emit('contextInk', item, event)
}
</script>

<template>
  <GlobalPointerProvider :document-id="documentId">
    <Viewport :document-id="documentId" class="absolute inset-0 bg-muted/40">
      <ZoomGestureWrapper :document-id="documentId">
        <Scroller :document-id="documentId">
          <template #default="{ page }">
            <Rotate :document-id="documentId" :page-index="page.pageIndex" :data-page-index="page.pageIndex" class="bg-background shadow-md">
              <PagePointerProvider :document-id="documentId" :page-index="page.pageIndex">
                <RenderLayer :document-id="documentId" :page-index="page.pageIndex" :scale="0.5" class="pointer-events-none" />
                <TilingLayer :document-id="documentId" :page-index="page.pageIndex" class="pointer-events-none" />
                <SearchLayer
                  :document-id="documentId"
                  :page-index="page.pageIndex"
                  highlight-color="color-mix(in oklch, var(--primary) 30%, transparent)"
                  active-highlight-color="color-mix(in oklch, var(--primary) 55%, transparent)"
                />
                <SelectionLayer
                  :document-id="documentId"
                  :page-index="page.pageIndex"
                  :text-style="{ background: 'color-mix(in oklch, var(--primary) 35%, transparent)' }"
                />
                <AnnotationLayer :document-id="documentId" :page-index="page.pageIndex" />
                <SourcePdfInkLayer
                  v-if="sourceInk?.length"
                  :document-id="documentId"
                  :page-index="page.pageIndex"
                  :width="page.width"
                  :height="page.height"
                  :items="sourceInk"
                  :selected-id="selectedInkId ?? null"
                  @select="handleSelectInk"
                  @context="handleContextInk"
                />
              </PagePointerProvider>
            </Rotate>
          </template>
        </Scroller>
      </ZoomGestureWrapper>
    </Viewport>
  </GlobalPointerProvider>
</template>
