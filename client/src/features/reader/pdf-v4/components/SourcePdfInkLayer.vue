<script setup lang="ts">
import { computed } from 'vue'
import type { AnnotationItem } from '@bookorbit/types'
import { useZoom } from '@embedpdf/plugin-zoom/vue'
import { useI18n } from 'vue-i18n'

const props = defineProps<{
  documentId: string
  pageIndex: number
  width: number
  height: number
  items: AnnotationItem[]
  selectedId: number | null
}>()
const emit = defineEmits<{ select: [item: AnnotationItem]; context: [item: AnnotationItem, event: MouseEvent] }>()
const { t } = useI18n()
const { state } = useZoom(() => props.documentId)
const viewBox = computed(() => `0 0 ${props.width / state.value.currentZoomLevel} ${props.height / state.value.currentZoomLevel}`)
const pageItems = computed(() => props.items.filter((item) => item.pdf?.page === props.pageIndex))
function handleSelect(item: AnnotationItem) {
  emit('select', item)
}
function handleContext(item: AnnotationItem, event: MouseEvent) {
  emit('context', item, event)
}
</script>

<template>
  <svg class="pointer-events-none absolute inset-0 z-20 h-full w-full overflow-visible" :viewBox="viewBox">
    <g v-for="item in pageItems" :key="item.id">
      <rect
        v-if="item.pdf"
        :x="item.pdf.rect.x"
        :y="item.pdf.rect.y"
        :width="item.pdf.rect.width"
        :height="item.pdf.rect.height"
        fill="transparent"
        :class="item.id === props.selectedId ? 'stroke-primary' : 'stroke-transparent'"
        stroke-width="2"
        vector-effect="non-scaling-stroke"
        class="pointer-events-auto cursor-pointer focus:outline-none focus:stroke-primary"
        tabindex="0"
        role="button"
        :aria-label="t('annotations.listItem.selectAnnotation')"
        :aria-pressed="item.id === props.selectedId"
        :data-testid="`source-ink-${item.id}`"
        @click.stop="handleSelect(item)"
        @keydown.enter.prevent="handleSelect(item)"
        @keydown.space.prevent="handleSelect(item)"
        @contextmenu.prevent.stop="handleContext(item, $event)"
      />
    </g>
  </svg>
</template>
