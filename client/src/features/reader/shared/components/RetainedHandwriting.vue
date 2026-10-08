<script setup lang="ts">
import { computed } from 'vue'
import { useI18n } from 'vue-i18n'
import type { NativeAnnotationDrawing } from '@bookorbit/types'

const props = defineProps<{ drawing: NativeAnnotationDrawing }>()
const { t } = useI18n()
const strokes = computed(() => props.drawing.strokes.filter((stroke) => stroke.points.length > 0))
const viewBox = computed(() => {
  let left = Infinity
  let top = Infinity
  let right = -Infinity
  let bottom = -Infinity
  for (const stroke of strokes.value) {
    for (const point of stroke.points) {
      left = Math.min(left, point.x - stroke.width)
      top = Math.min(top, point.y - stroke.width)
      right = Math.max(right, point.x + stroke.width)
      bottom = Math.max(bottom, point.y + stroke.width)
    }
  }
  return Number.isFinite(left) ? `${left} ${top} ${Math.max(1, right - left)} ${Math.max(1, bottom - top)}` : '0 0 1 1'
})
function points(stroke: NativeAnnotationDrawing['strokes'][number]) {
  return stroke.points.map((point) => `${point.x},${point.y}`).join(' ')
}
</script>

<template>
  <svg
    :viewBox="viewBox"
    role="img"
    :aria-label="t('reader.note.title')"
    class="my-2 h-28 w-full rounded-md border border-border bg-background dark:bg-foreground"
    data-testid="passage-handwriting"
  >
    <polyline
      v-for="stroke in strokes"
      :key="stroke.id"
      :points="points(stroke)"
      :stroke="stroke.color"
      :stroke-width="stroke.width"
      fill="none"
      stroke-linecap="round"
      stroke-linejoin="round"
    />
  </svg>
</template>
