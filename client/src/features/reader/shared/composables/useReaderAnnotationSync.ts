import { getCurrentInstance, onUnmounted, type Ref } from 'vue'
import type { AnnotationItem, NativeAnnotationDelta } from '@bookorbit/types'
import { api } from '@/lib/api'

export function useReaderAnnotationSync(
  annotations: Ref<AnnotationItem[]>,
  bookId: () => number | null,
  fileId: () => number | null,
  maxLoaded = 100,
  refreshCollection?: () => Promise<boolean | void>,
) {
  let cursor = '0'
  let busy = false
  let disposed = false
  let scope: number | null = null
  let catchupTimer: ReturnType<typeof setTimeout> | null = null
  let mutationGeneration = 0
  let refreshPending = false

  function invalidate() {
    mutationGeneration += 1
  }

  async function synchronize() {
    const book = bookId()
    if (busy || disposed || book === null || document.visibilityState === 'hidden') return
    if (scope !== book) {
      scope = book
      cursor = '0'
      refreshPending = false
    }
    busy = true
    const generation = mutationGeneration
    try {
      const query = new URLSearchParams({ bookId: String(book), cursor, limit: '100' })
      const response = await api(`/api/v1/annotations/native/delta?${query}`)
      if (!response.ok || disposed || scope !== book || generation !== mutationGeneration) return
      const delta: NativeAnnotationDelta = await response.json()
      if (generation !== mutationGeneration) return
      const rows = new Map(annotations.value.map((item) => [item.id, item]))
      for (const item of delta.items) {
        const previous = rows.get(item.id)
        if (previous && (previous.version ?? 0) >= item.version) continue
        const belongsToFile = fileId() === null || item.jumpFileId === fileId()
        if (item.kind === 'pdf_ink') continue
        if (previous || belongsToFile) refreshPending = true
        if (item.deletedAt || !belongsToFile) rows.delete(item.id)
        else if (previous || rows.size < maxLoaded) rows.set(item.id, item)
      }
      annotations.value = [...rows.values()]
      if (!delta.hasMore && refreshPending) {
        if (!refreshCollection || (await refreshCollection()) === false) return
        refreshPending = false
      }
      if (generation !== mutationGeneration) return
      cursor = delta.nextCursor
      if (delta.hasMore) catchupTimer = setTimeout(() => void synchronize(), 0)
    } catch {
      // Reconnection retries from the last acknowledged cursor.
    } finally {
      busy = false
    }
  }

  if (!getCurrentInstance()) return { synchronize, invalidate }
  const timer = setInterval(() => void synchronize(), 3000)
  window.addEventListener('online', synchronize)
  window.addEventListener('focus', synchronize)
  onUnmounted(() => {
    disposed = true
    clearInterval(timer)
    if (catchupTimer) clearTimeout(catchupTimer)
    window.removeEventListener('online', synchronize)
    window.removeEventListener('focus', synchronize)
  })
  return { synchronize, invalidate }
}
