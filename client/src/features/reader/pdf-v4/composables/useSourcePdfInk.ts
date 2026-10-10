import { computed, onUnmounted, ref } from 'vue'
import {
  Permission,
  type AnnotationItem,
  type NativeAnnotationDelta,
  type NativeAnnotationOperationsResponse,
  type NativePdfPageSource,
  type NativePdfPageSourceBatch,
  type NativeSourceInkWindowResponse,
} from '@bookorbit/types'
import { api } from '@/lib/api'
import { usePermissions } from '@/features/auth/composables/usePermissions'

export function useSourcePdfInk(bookId: number, fileId: number) {
  const annotations = ref<AnnotationItem[]>([])
  const { hasPermission } = usePermissions()
  const source = ref<NativePdfPageSource | null>(null)
  const pageSources = ref(new Map<number, NativePdfPageSource>())
  const sourceRevision = computed(() => source.value?.sourceRevision ?? null)
  const canEdit = computed(() => hasPermission(Permission.LibraryEditMetadata) && source.value?.canEditPdfInk === true)
  const selectedId = ref<number | null>(null)
  const menu = ref<{ x: number; y: number } | null>(null)
  const hiddenId = ref<number | null>(null)
  const undoItem = ref<AnnotationItem | null>(null)
  const busy = ref(false)
  const failed = ref(false)
  const committed = ref(false)
  const undoRequested = ref(false)
  const publicationFailed = ref(false)
  const pageWindow = ref(1)
  const pageTotals = ref(new Map<number, number>())
  const loadingWindow = ref(false)
  const pinnedItem = ref<AnnotationItem | null>(null)
  const windowCount = computed(() => Math.max(1, ...[...pageTotals.value.values()].map((total) => Math.ceil(total / 100))))
  const hasPrevious = computed(() => pageWindow.value > 1)
  const hasMore = computed(() => pageWindow.value < windowCount.value)
  const items = computed(() =>
    [
      ...annotations.value,
      ...(pinnedItem.value && !annotations.value.some((item) => item.id === pinnedItem.value?.id) ? [pinnedItem.value] : []),
    ].filter(
      (item) =>
        item.kind === 'pdf_ink' &&
        item.pdf &&
        !item.deletedAt &&
        item.id !== hiddenId.value &&
        item.pageFingerprint != null &&
        item.pageFingerprint === pageSources.value.get(item.pdf.page)?.pageFingerprint,
    ),
  )
  const selected = computed(() => items.value.find((item) => item.id === selectedId.value) ?? null)
  let pending: ReturnType<typeof setTimeout> | null = null
  let pendingOperationId: string | null = null
  let deleteItem: AnnotationItem | null = null
  let publicationAction: 'delete' | 'restore' = 'delete'
  let inverseOperationId: string | null = null
  let inspecting = false
  let disposed = false
  let visiblePages = [0]
  let scopeGeneration = 0
  let synchronizing = false
  let catchupTimer: ReturnType<typeof setTimeout> | null = null
  const cursors = new Map<number, string>()
  const versions = new Map<number, number>()
  let snapshotRequest = 0

  async function loadWindow(): Promise<boolean> {
    if (disposed || document.visibilityState === 'hidden') return false
    const request = ++snapshotRequest
    const generation = scopeGeneration
    const ordinal = pageWindow.value
    const pages = [...visiblePages]
    loadingWindow.value = true
    try {
      const rows: AnnotationItem[] = []
      const totals = new Map<number, number>()
      for (const page of pages) {
        const query = new URLSearchParams({
          bookId: String(bookId),
          bookFileId: String(fileId),
          page: String(page),
          window: String(ordinal),
          limit: '100',
        })
        const response = await api(`/api/v1/annotations/native/source-ink/window?${query}`)
        if (!response.ok) throw new Error('Source ink window unavailable')
        const snapshot: NativeSourceInkWindowResponse = await response.json()
        if (disposed || generation !== scopeGeneration || request !== snapshotRequest) return false
        totals.set(page, snapshot.total)
        rows.push(...snapshot.items.filter((item) => (versions.get(item.id) ?? 0) <= item.version).map((item) => ({ ...item, drawing: null })))
      }
      pageTotals.value = totals
      if (ordinal > windowCount.value) {
        pageWindow.value = windowCount.value
        return await loadWindow()
      }
      annotations.value = rows
      const retainedIds = new Set(rows.map((item) => item.id))
      for (const item of rows) versions.set(item.id, item.version ?? 1)
      for (const id of versions.keys()) {
        if (!retainedIds.has(id) && id !== undoItem.value?.id && id !== pinnedItem.value?.id) versions.delete(id)
      }
      if (!undoItem.value) failed.value = false
      return true
    } catch {
      if (generation === scopeGeneration && request === snapshotRequest) failed.value = true
      return false
    } finally {
      if (request === snapshotRequest) loadingWindow.value = false
    }
  }

  async function changeWindow(ordinal: number) {
    if (loadingWindow.value || ordinal < 1 || ordinal > windowCount.value) return
    scopeGeneration += 1
    pageWindow.value = ordinal
    annotations.value = []
    dismiss()
    await loadWindow()
  }

  function loadNextWindow() {
    return changeWindow(pageWindow.value + 1)
  }

  function loadPreviousWindow() {
    return changeWindow(pageWindow.value - 1)
  }

  async function synchronize() {
    if (synchronizing || loadingWindow.value || disposed || document.visibilityState === 'hidden') return
    synchronizing = true
    const generation = scopeGeneration
    let hasMore = false
    try {
      for (const page of visiblePages) {
        const query = new URLSearchParams({
          bookId: String(bookId),
          bookFileId: String(fileId),
          cursor: cursors.get(page) ?? '0',
          page: String(page),
          limit: '100',
        })
        const response = await api(`/api/v1/annotations/native/source-ink?${query}`)
        if (!response.ok) {
          failed.value = true
          return
        }
        if (disposed || generation !== scopeGeneration) return
        const delta: NativeAnnotationDelta = await response.json()
        if (delta.items.length && !(await loadWindow())) return
        if (disposed || generation !== scopeGeneration) return
        for (const item of delta.items) {
          if (item.id === pinnedItem.value?.id && item.version >= (pinnedItem.value.version ?? 0)) {
            pinnedItem.value = item.deletedAt ? null : { ...item, drawing: null }
          }
        }
        cursors.set(page, delta.nextCursor)
        hasMore ||= delta.hasMore
      }
      if (!undoItem.value) failed.value = false
    } catch {
      failed.value = true
    } finally {
      synchronizing = false
      if (!disposed && (hasMore || generation !== scopeGeneration)) catchupTimer = setTimeout(() => void synchronize(), 0)
    }
  }

  function setVisiblePages(start: number, end: number) {
    const next = Array.from({ length: Math.min(4, Math.max(1, end - start + 1)) }, (_, offset) => Math.max(0, start) + offset)
    if (visiblePages.join(',') === next.join(',')) return
    visiblePages = next
    scopeGeneration += 1
    cursors.clear()
    versions.clear()
    annotations.value = []
    pageWindow.value = 1
    pageTotals.value = new Map()
    pageSources.value = new Map()
    dismiss()
    void inspectSource()
    void loadWindow()
    void synchronize()
  }

  async function inspectSource() {
    if (inspecting || disposed || document.visibilityState === 'hidden') return
    inspecting = true
    const generation = scopeGeneration
    const pages = [...visiblePages]
    try {
      const query = new URLSearchParams({ bookId: String(bookId), pageStart: String(pages[0]), limit: String(pages.length) })
      const response = await api(`/api/v1/annotations/native/files/${fileId}/source?${query}`)
      if (!disposed && generation === scopeGeneration) {
        const batch: NativePdfPageSourceBatch | null = response.ok ? await response.json() : null
        const next = batch?.pages[0] ?? null
        if (next && source.value && next.sourceRevision !== source.value.sourceRevision) {
          scopeGeneration += 1
          void loadWindow()
          void synchronize()
        }
        pageSources.value = new Map(batch?.pages.map((page) => [page.page, page]))
        source.value = next
        if (!response.ok) failed.value = true
      }
    } catch {
      // Keep the last verified source while the next connection is attempted.
    } finally {
      inspecting = false
      if (!disposed && pages.join(',') !== visiblePages.join(',')) void inspectSource()
    }
  }

  function select(item: AnnotationItem, event?: MouseEvent) {
    selectedId.value = item.id
    menu.value = event ? { x: Math.min(event.clientX, window.innerWidth - 180), y: Math.min(event.clientY, window.innerHeight - 100) } : null
  }

  function dismiss() {
    selectedId.value = null
    menu.value = null
    pinnedItem.value = null
  }

  async function operation(item: AnnotationItem, action: 'delete' | 'restore', operationId: string) {
    publicationAction = action
    const response = await api(`/api/v1/annotations/native/source-ink/${bookId}/${fileId}/operations`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        deviceId: 'web-reader',
        operations: [
          { operationId, clientId: item.clientId ?? crypto.randomUUID(), annotationId: item.id, bookId, baseVersion: item.version ?? 1, action },
        ],
      }),
    })
    if (!response.ok) return null
    const result: NativeAnnotationOperationsResponse = await response.json()
    const applied = result.results.find((entry) => entry.operationId === operationId)
    publicationFailed.value = applied?.publication?.status === 'failed'
    if (publicationFailed.value) failed.value = true
    if (applied?.status === 'applied' && applied.annotation) versions.set(applied.annotation.id, applied.annotation.version)
    if (applied?.publication?.status === 'published') void inspectSource()
    return applied?.status === 'applied' ? (applied.annotation ?? null) : null
  }

  async function publishDelete() {
    pending = null
    const item = deleteItem
    if (!item || !pendingOperationId) return
    busy.value = true
    failed.value = false
    try {
      const deleted = await operation(item, 'delete', pendingOperationId)
      if (!deleted) {
        failed.value = true
        hiddenId.value = null
        return
      }
      undoItem.value = deleted
      committed.value = true
      annotations.value = annotations.value.filter((entry) => entry.id !== item.id)
      if (pinnedItem.value?.id === item.id) pinnedItem.value = null
      hiddenId.value = null
      void loadWindow()
    } catch {
      failed.value = true
      hiddenId.value = null
    } finally {
      busy.value = false
    }
    if (undoRequested.value && committed.value) await undo()
  }

  function removeSelected() {
    if (!canEdit.value || busy.value || pending || !selected.value) return
    deleteItem = { ...selected.value, clientId: selected.value.clientId ?? crypto.randomUUID() }
    undoItem.value = deleteItem
    hiddenId.value = selected.value.id
    pendingOperationId = crypto.randomUUID()
    inverseOperationId = null
    committed.value = false
    undoRequested.value = false
    failed.value = false
    publicationFailed.value = false
    dismiss()
    pending = setTimeout(() => void publishDelete(), 350)
  }

  async function undo() {
    if (!canEdit.value || !undoItem.value) return
    if (pending) {
      clearTimeout(pending)
      pending = null
      hiddenId.value = null
      undoItem.value = null
      pendingOperationId = null
      deleteItem = null
      return
    }
    if (busy.value) {
      undoRequested.value = true
      return
    }
    if (!committed.value) {
      undoRequested.value = true
      await publishDelete()
      return
    }
    busy.value = true
    failed.value = false
    try {
      inverseOperationId ??= crypto.randomUUID()
      const restored = await operation(undoItem.value, 'restore', inverseOperationId)
      if (!restored) {
        failed.value = true
        return
      }
      pinnedItem.value = { ...restored, drawing: null }
      selectedId.value = restored.id
      void loadWindow()
      if (publicationFailed.value) return
      undoItem.value = null
      pendingOperationId = null
      deleteItem = null
      committed.value = false
      undoRequested.value = false
    } catch {
      failed.value = true
    } finally {
      busy.value = false
    }
  }

  function retry() {
    if (publicationFailed.value && publicationAction === 'restore') void undo()
    else if (publicationFailed.value && pendingOperationId) void publishDelete()
    else if (committed.value) void undo()
    else if (pendingOperationId) void publishDelete()
    else {
      void inspectSource()
      void loadWindow()
      void synchronize()
    }
  }

  onUnmounted(() => {
    disposed = true
    clearInterval(sourceTimer)
    if (catchupTimer) clearTimeout(catchupTimer)
    if (pending) {
      clearTimeout(pending)
      void publishDelete()
    }
  })
  const sourceTimer = setInterval(() => {
    void inspectSource()
    void synchronize()
  }, 3000)
  void inspectSource()
  void loadWindow()
  void synchronize()
  return {
    items,
    canEdit,
    sourceRevision,
    selectedId,
    selected,
    menu,
    undoItem,
    busy,
    failed,
    committed,
    select,
    dismiss,
    removeSelected,
    undo,
    retry,
    setVisiblePages,
    pageWindow,
    windowCount,
    hasPrevious,
    hasMore,
    loadingWindow,
    loadNextWindow,
    loadPreviousWindow,
  }
}
