<script setup lang="ts">
import { nextTick, provide, ref, watch } from 'vue'
import { useViewportPlugin } from '@embedpdf/plugin-viewport/vue'

const props = defineProps<{
  documentId: string
  pageWidth: number
  padding: { top: number; right: number; bottom: number; left: number }
}>()
const emit = defineEmits<{ ready: [] }>()
const { plugin } = useViewportPlugin()
const host = ref<HTMLElement | null>(null)
const canvas = ref<HTMLElement | null>(null)
provide('viewport-element', host)

function origin() {
  return { x: (canvas.value?.offsetLeft ?? 0) + props.padding.left, y: props.padding.top }
}

// Reader geometry stays in PDF coordinates while the DOM also includes saved margin ink.
function report() {
  const element = host.value
  if (!element || !plugin.value) return
  const offset = origin()
  plugin.value.setViewportResizeMetrics(props.documentId, {
    width: element.offsetWidth,
    height: element.offsetHeight,
    clientWidth: element.clientWidth,
    clientHeight: element.clientHeight,
    scrollWidth: element.scrollWidth,
    scrollHeight: element.scrollHeight,
    scrollLeft: element.scrollLeft - offset.x,
    scrollTop: element.scrollTop - offset.y,
    clientLeft: element.clientLeft,
    clientTop: element.clientTop,
  })
}

function onScroll() {
  const offset = origin()
  if (host.value)
    plugin.value?.setViewportScrollMetrics(props.documentId, {
      scrollLeft: host.value.scrollLeft - offset.x,
      scrollTop: host.value.scrollTop - offset.y,
    })
}

watch(
  [plugin, host, () => props.documentId],
  ([viewport, element, documentId], _, onCleanup) => {
    if (!viewport || !element) return
    viewport.registerViewport(documentId)
    const resize = new ResizeObserver(report)
    resize.observe(element)
    if (canvas.value) resize.observe(canvas.value)
    const unsubscribe = viewport.onScrollRequest(documentId, ({ x, y, behavior }) => {
      void nextTick(() => {
        const offset = origin()
        element.scrollTo({ left: x + offset.x, top: y + offset.y, behavior })
      })
    })
    report()
    emit('ready')
    onCleanup(() => {
      resize.disconnect()
      unsubscribe()
      viewport.unregisterViewport(documentId)
    })
  },
  { flush: 'post' },
)
watch(
  () => props.padding,
  () => void nextTick(report),
)
</script>

<template>
  <div ref="host" class="absolute inset-0 overflow-auto bg-muted/40" data-proof-ink-viewport @scroll="onScroll">
    <div
      ref="canvas"
      class="relative mx-auto"
      :style="{
        boxSizing: 'content-box',
        width: `${pageWidth}px`,
        padding: `${padding.top}px ${padding.right}px ${padding.bottom}px ${padding.left}px`,
      }"
    >
      <slot />
    </div>
  </div>
</template>
