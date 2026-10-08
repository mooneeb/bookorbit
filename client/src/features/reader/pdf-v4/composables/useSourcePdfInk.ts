import { computed, onUnmounted, ref } from 'vue'
import {
  Permission,
  type AnnotationItem,
  type NativeAnnotationDelta,
  type NativeAnnotationOperationsResponse,
  type NativePdfPageSource,
  type NativePdfPageSourceBatch,
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
  const items = computed(() =>
    annotations.value.filter(
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

  async function synchronize() {
    if (synchronizing || disposed || document.visibilityState === 'hidden') return
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
        const rows = new Map(annotations.value.map((item) => [item.id, item]))
        for (const item of delta.items) {
          if ((versions.get(item.id) ?? rows.get(item.id)?.version ?? 0) > item.version) continue
          versions.set(item.id, item.version)
          if (item.deletedAt) rows.delete(item.id)
          else rows.set(item.id, { ...item, drawing: null })
        }
        annotations.value = [...rows.values()].slice(-1000)
        const retainedIds = new Set(annotations.value.map((item) => item.id))
        for (const id of versions.keys()) {
          if (!retainedIds.has(id) && id !== undoItem.value?.id) versions.delete(id)
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
    pageSources.value = new Map()
    dismiss()
    void inspectSource()
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
          cursors.clear()
          annotations.value = []
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
      hiddenId.value = null
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
      annotations.value = [...annotations.value.filter((entry) => entry.id !== restored.id), restored]
      selectedId.value = restored.id
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
  }
}
