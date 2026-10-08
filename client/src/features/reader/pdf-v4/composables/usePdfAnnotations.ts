import { computed, getCurrentInstance, onUnmounted, ref } from 'vue'
import type { AnnotationItem, AnnotationListResponse, AnnotationPdfPosition } from '@bookorbit/types'
import { api, getValidToken } from '@/lib/api'
import { useReaderAnnotationSync } from '../../shared/composables/useReaderAnnotationSync'
import { applyReaderAnnotationOperation } from '../../shared/lib/reader-annotation-operation'

export interface PdfAnnotationPatch {
  baseVersion?: number
  note?: string | null
  color?: string
  style?: string
}

export interface CreatePdfAnnotationInput {
  pdf: AnnotationPdfPosition
  bookFileId: number
  text: string
  color: string
  style: string
  note?: string | null
}

/**
 * REST client and reactive store for a book's annotations, scoped to the PDF
 * reader. Talks to the same `/books/:bookId/annotations` endpoints as the EPUB
 * reader; only the create payload carries a PDF position instead of a CFI.
 */
const PAGE_SIZE = 100
const VISIBLE_WINDOW_SIZE = 1000

export function usePdfAnnotations(bookId: number, bookFileId: number) {
  const annotations = ref<AnnotationItem[]>([])
  const total = ref(0)
  const loadError = ref(false)
  const loading = ref(false)
  const loadingMore = ref(false)
  const page = ref(1)
  const hasMore = computed(() => page.value * PAGE_SIZE < total.value)
  const hasPrevious = computed(() => page.value > 1)
  const visibleAnnotations = ref<AnnotationItem[]>([])
  const visibleTotals = ref<number[]>([])
  const visibleWindow = ref(1)
  const visibleHasMore = computed(() => visibleTotals.value.some((count) => count > visibleWindow.value * VISIBLE_WINDOW_SIZE))
  const visibleHasPrevious = computed(() => visibleWindow.value > 1)
  const visibleWindowCount = computed(() => Math.max(1, ...visibleTotals.value.map((count) => Math.ceil(count / VISIBLE_WINDOW_SIZE))))
  const loadingVisible = ref(false)
  const scopedRendering = ref(false)
  let visiblePages: number[] = []
  let visibleGeneration = 0
  let sidebarGeneration = 0
  let disposed = false
  const renderAnnotations = computed(() => (scopedRendering.value ? visibleAnnotations.value : annotations.value))
  let mutationRevision = 0
  const { synchronize, invalidate } = useReaderAnnotationSync(
    annotations,
    () => bookId,
    () => bookFileId,
    PAGE_SIZE,
    refreshCollections,
  )

  async function fetchAnnotationPage(page: number, pdfPage?: number): Promise<Response> {
    const token = await getValidToken()
    const headers = new Headers()
    if (token) headers.set('Authorization', `Bearer ${token}`)
    return fetch(annotationPageUrl(page, pdfPage), { headers, credentials: 'include' })
  }

  async function fetchStableAnnotationPage(pageNumber: number, pdfPage?: number): Promise<AnnotationListResponse | null> {
    while (true) {
      if (disposed) return null
      const requestRevision = mutationRevision
      const res = await fetchAnnotationPage(pageNumber, pdfPage)
      if (!res.ok) return null
      const page: AnnotationListResponse = await res.json()
      if (requestRevision === mutationRevision) return page
    }
  }

  async function loadSidebar(pageNumber: number) {
    const generation = ++sidebarGeneration
    try {
      const result = await fetchStableAnnotationPage(pageNumber)
      if (disposed || generation !== sidebarGeneration) return false
      if (!result) {
        loadError.value = true
        return false
      }
      if (pageNumber > 1 && result.items.length === 0) {
        return loadSidebar(Math.max(1, Math.ceil(result.total / PAGE_SIZE)))
      }
      annotations.value = result.items
      total.value = result.total
      page.value = result.page
      loadError.value = false
      return true
    } catch {
      loadError.value = true
      return false
    }
  }

  async function loadVisible() {
    if (!visiblePages.length) return true
    if (loadingVisible.value) return false
    loadingVisible.value = true
    const generation = visibleGeneration
    const revision = mutationRevision
    const pages = [...visiblePages]
    const firstBatch = (visibleWindow.value - 1) * (VISIBLE_WINDOW_SIZE / PAGE_SIZE) + 1
    try {
      const rows: AnnotationItem[] = []
      const totals: number[] = []
      for (const pdfPage of pages) {
        for (let batch = firstBatch; batch < firstBatch + VISIBLE_WINDOW_SIZE / PAGE_SIZE; batch += 1) {
          const result = await fetchStableAnnotationPage(batch, pdfPage)
          if (!result) {
            loadError.value = true
            return false
          }
          if (disposed || generation !== visibleGeneration || revision !== mutationRevision) return false
          if (batch === firstBatch) totals.push(result.total)
          rows.push(...result.items)
          if (batch * PAGE_SIZE >= result.total) break
        }
      }
      visibleAnnotations.value = rows
      visibleTotals.value = totals
      loadError.value = false
      return true
    } catch {
      loadError.value = true
      return false
    } finally {
      loadingVisible.value = false
      if (!disposed && (generation !== visibleGeneration || revision !== mutationRevision)) void loadVisible()
    }
  }

  async function refreshCollections() {
    const sidebarLoaded = await loadSidebar(page.value)
    const visibleLoaded = await loadVisible()
    return sidebarLoaded && visibleLoaded
  }

  async function load() {
    if (loading.value) return false
    loading.value = true
    loadError.value = false
    invalidate()
    try {
      const loaded = await refreshCollections()
      if (loaded) void synchronize()
      return loaded
    } finally {
      loading.value = false
    }
  }

  async function loadMore() {
    if (loading.value || loadingMore.value || !hasMore.value) return false
    loadingMore.value = true
    invalidate()
    try {
      return await loadSidebar(page.value + 1)
    } finally {
      loadingMore.value = false
    }
  }

  async function loadPrevious() {
    if (loading.value || loadingMore.value || !hasPrevious.value) return false
    loadingMore.value = true
    invalidate()
    try {
      return await loadSidebar(page.value - 1)
    } finally {
      loadingMore.value = false
    }
  }

  function setVisiblePages(start: number, end: number) {
    const pages = Array.from({ length: Math.min(4, Math.max(1, end - start + 1)) }, (_, index) => Math.max(0, start) + index)
    if (pages.join(',') === visiblePages.join(',')) return
    visiblePages = pages
    scopedRendering.value = true
    visibleWindow.value = 1
    visibleGeneration += 1
    visibleAnnotations.value = annotations.value.filter((annotation) => annotation.pdf && pages.includes(annotation.pdf.page))
    visibleTotals.value = []
    void loadVisible()
  }

  async function changeVisibleWindow(direction: -1 | 1) {
    if (loadingVisible.value || (direction === -1 ? !visibleHasPrevious.value : !visibleHasMore.value)) return
    visibleWindow.value += direction
    visibleGeneration += 1
    await loadVisible()
  }

  function loadMoreVisible() {
    return changeVisibleWindow(1)
  }

  function loadPreviousVisible() {
    return changeVisibleWindow(-1)
  }

  function annotationPageUrl(page: number, pdfPage?: number) {
    const query = new URLSearchParams({
      page: String(page),
      pageSize: String(PAGE_SIZE),
      sortBy: 'position',
      sortDir: 'asc',
      bookFileId: String(bookFileId),
      excludeSourceInk: 'true',
    })
    if (pdfPage !== undefined) query.set('pdfPage', String(pdfPage))
    return `/api/v1/books/${bookId}/annotations?${query.toString()}`
  }

  async function create(input: CreatePdfAnnotationInput): Promise<AnnotationItem | null> {
    try {
      const res = await api(`/api/v1/books/${bookId}/annotations`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(input),
      })
      if (!res.ok) return null
      invalidate()
      const created: AnnotationItem = await res.json()
      annotations.value = [...annotations.value, created]
      if (annotations.value.length > PAGE_SIZE) annotations.value = annotations.value.slice(0, PAGE_SIZE)
      if (
        created.pdf &&
        visiblePages.includes(created.pdf.page) &&
        visibleAnnotations.value.filter((annotation) => annotation.pdf?.page === created.pdf?.page).length < VISIBLE_WINDOW_SIZE
      ) {
        visibleAnnotations.value = [...visibleAnnotations.value, created]
      }
      total.value += 1
      mutationRevision += 1
      if (visiblePages.length) void refreshCollections()
      return created
    } catch {
      return null
    }
  }

  async function update(id: number, patch: PdfAnnotationPatch): Promise<AnnotationItem | null> {
    try {
      const { baseVersion, ...payload } = patch
      const previous = [...annotations.value, ...visibleAnnotations.value].find((annotation) => annotation.id === id)
      const version = baseVersion ?? previous?.version
      if (version !== undefined) {
        const updated = await applyReaderAnnotationOperation(bookId, id, version, previous?.clientId, 'update', payload)
        if (!updated) return null
        invalidate()
        annotations.value = annotations.value.map((annotation) => (annotation.id === id ? updated : annotation))
        visibleAnnotations.value = visibleAnnotations.value.map((annotation) => (annotation.id === id ? updated : annotation))
        mutationRevision += 1
        return updated
      }
      const res = await api(`/api/v1/books/${bookId}/annotations/${id}`, {
        method: 'PATCH',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(payload),
      })
      if (!res.ok) return null
      const updated: AnnotationItem = await res.json()
      invalidate()
      annotations.value = annotations.value.map((a) => (a.id === id ? updated : a))
      visibleAnnotations.value = visibleAnnotations.value.map((annotation) => (annotation.id === id ? updated : annotation))
      mutationRevision += 1
      return updated
    } catch {
      return null
    }
  }

  async function remove(id: number): Promise<boolean> {
    try {
      const annotation = [...annotations.value, ...visibleAnnotations.value].find((item) => item.id === id)
      if (annotation?.version !== undefined) {
        const removed = await applyReaderAnnotationOperation(bookId, id, annotation.version, annotation.clientId, 'delete')
        if (!removed) return false
        invalidate()
        annotations.value = annotations.value.filter((item) => item.id !== id)
        visibleAnnotations.value = visibleAnnotations.value.filter((item) => item.id !== id)
        total.value = Math.max(0, total.value - 1)
        mutationRevision += 1
        return true
      }
      const res = await api(`/api/v1/books/${bookId}/annotations/${id}`, {
        method: 'DELETE',
      })
      if (!res.ok) return false
      invalidate()
      annotations.value = annotations.value.filter((a) => a.id !== id)
      visibleAnnotations.value = visibleAnnotations.value.filter((a) => a.id !== id)
      total.value = Math.max(0, total.value - 1)
      mutationRevision += 1
      return true
    } catch {
      return false
    }
  }

  if (getCurrentInstance()) {
    onUnmounted(() => {
      disposed = true
      sidebarGeneration += 1
      visibleGeneration += 1
    })
  }

  return {
    annotations,
    renderAnnotations,
    total,
    loadError,
    loading,
    loadingMore,
    hasMore,
    hasPrevious,
    page,
    visibleWindow,
    visibleWindowCount,
    visibleHasMore,
    visibleHasPrevious,
    loadingVisible,
    load,
    loadMore,
    loadPrevious,
    setVisiblePages,
    loadMoreVisible,
    loadPreviousVisible,
    create,
    update,
    remove,
  }
}
