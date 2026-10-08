import { computed, ref } from 'vue'
import type { AnnotationItem, AnnotationListResponse, CreateAnnotationPayload } from '@bookorbit/types'
import { api } from '@/lib/api'
import { useReaderAnnotationSync } from '../../shared/composables/useReaderAnnotationSync'
import { applyReaderAnnotationOperation } from '../../shared/lib/reader-annotation-operation'

export type Annotation = AnnotationItem

export interface AnnotationPatch {
  baseVersion?: number
  note?: string | null
  color?: string
  style?: string
}

export function useAnnotations() {
  const annotations = ref<Annotation[]>([])
  const loadError = ref<string | null>(null)
  const loadingMore = ref(false)
  const total = ref(0)
  const page = ref(1)
  let loadedBookId: number | null = null
  let loadedFileId: number | null = null
  let loadGeneration = 0
  const hasMore = computed(() => page.value * 100 < total.value)
  const { synchronize, invalidate } = useReaderAnnotationSync(
    annotations,
    () => loadedBookId,
    () => loadedFileId,
    100,
    refreshCollection,
  )

  async function refreshCollection() {
    if (loadedBookId === null) return false
    return load(loadedBookId, loadedFileId ?? undefined, page.value, true)
  }

  async function load(bookId: number, bookFileId?: number, pageNumber = 1, refreshing = false) {
    const generation = ++loadGeneration
    loadError.value = null
    loadedBookId = bookId
    loadedFileId = bookFileId ?? null
    if (!refreshing) invalidate()
    const query = new URLSearchParams({ page: String(pageNumber), pageSize: '100', sortBy: 'position', sortDir: 'asc' })
    if (bookFileId) query.set('bookFileId', String(bookFileId))
    try {
      const res = await api(`/api/v1/books/${bookId}/annotations?${query}`)
      if (!res.ok) {
        loadError.value = 'Failed to load'
        return false
      }
      const result: AnnotationListResponse = await res.json()
      if (generation !== loadGeneration) return false
      if (pageNumber > 1 && result.items.length === 0) {
        return load(bookId, bookFileId, Math.max(1, Math.ceil(result.total / 100)), refreshing)
      }
      annotations.value = result.items
      total.value = result.total
      page.value = result.page
      if (!refreshing) void synchronize()
      return true
    } catch {
      loadError.value = 'Failed to load'
      return false
    }
  }

  async function loadMore() {
    if (!loadedBookId || loadingMore.value || !hasMore.value) return
    loadingMore.value = true
    try {
      await load(loadedBookId, loadedFileId ?? undefined, page.value + 1)
    } finally {
      loadingMore.value = false
    }
  }

  async function loadPrevious() {
    if (loadedBookId && page.value > 1) await load(loadedBookId, loadedFileId ?? undefined, page.value - 1)
  }

  async function create(bookId: number, data: Omit<CreateAnnotationPayload, 'pdf'> & { cfi: string }): Promise<Annotation | null> {
    const res = await api(`/api/v1/books/${bookId}/annotations`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(data),
    })
    if (!res.ok) return null
    invalidate()
    const created: Annotation = await res.json()
    if (annotations.value.length < 100) annotations.value = [...annotations.value, created]
    total.value += 1
    if (annotations.value.length >= 100) void refreshCollection()
    return created
  }

  async function update(bookId: number, id: number, data: AnnotationPatch): Promise<Annotation | null> {
    const { baseVersion, ...patch } = data
    const previous = annotations.value.find((annotation) => annotation.id === id)
    const version = baseVersion ?? previous?.version
    if (version !== undefined) {
      const updated = await applyReaderAnnotationOperation(bookId, id, version, previous?.clientId, 'update', patch)
      if (!updated) return null
      invalidate()
      annotations.value = annotations.value.map((annotation) => (annotation.id === id ? updated : annotation))
      return updated
    }
    const res = await api(`/api/v1/books/${bookId}/annotations/${id}`, {
      method: 'PATCH',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(patch),
    })
    if (!res.ok) return null
    invalidate()

    const updated: Annotation = await res.json()
    annotations.value = annotations.value.map((a) => (a.id === id ? updated : a))
    return updated
  }

  function updateNote(bookId: number, id: number, note: string | null): Promise<Annotation | null> {
    return update(bookId, id, { note })
  }

  async function remove(bookId: number, id: number) {
    const annotation = annotations.value.find((item) => item.id === id)
    if (annotation?.version !== undefined) {
      const removed = await applyReaderAnnotationOperation(bookId, id, annotation.version, annotation.clientId, 'delete')
      if (removed) {
        invalidate()
        annotations.value = annotations.value.filter((item) => item.id !== id)
        total.value = Math.max(0, total.value - 1)
      }
      return
    }
    const res = await api(`/api/v1/books/${bookId}/annotations/${id}`, {
      method: 'DELETE',
    })
    if (res.ok) {
      invalidate()
      annotations.value = annotations.value.filter((a) => a.id !== id)
      total.value = Math.max(0, total.value - 1)
    }
  }

  return { annotations, loadError, loadingMore, hasMore, page, load, loadMore, loadPrevious, create, update, updateNote, remove }
}
