import { computed, ref } from 'vue'
import type { BookmarkResponse, BookmarksPage, CreateFixedPageBookmarkPayload } from '@bookorbit/types'
import { api } from '@/lib/api'

export function useFixedPageBookmarks(bookId: () => number, fileId: () => number) {
  const items = ref<BookmarkResponse[]>([])
  const loading = ref(false)
  const saving = ref(false)
  const loaded = ref(false)
  const error = ref(false)
  const outcome = ref<'saved' | 'removed' | null>(null)
  const nextCursor = ref<number | null>(null)
  const history = ref<Array<number | null>>([])
  const hasPrevious = computed(() => history.value.length > 0)
  const hasAcknowledgedBookmark = computed(() => !loaded.value && items.value.length > 0)
  let cursor: number | null = null
  let generation = 0
  let controller: AbortController | null = null

  async function load(requested: number | null = cursor): Promise<boolean> {
    if (loading.value || saving.value) return false
    const turn = generation
    controller = new AbortController()
    loading.value = true
    error.value = false
    try {
      const query = new URLSearchParams({ fileId: String(fileId()), limit: '40' })
      if (requested !== null) query.set('beforeId', String(requested))
      const response = await api(`/api/v1/books/${bookId()}/bookmarks/page?${query}`, { signal: controller.signal })
      if (!response.ok) throw new Error('Bookmark request failed')
      const page: BookmarksPage = await response.json()
      if (turn !== generation) return false
      if (!Array.isArray(page.items) || page.items.length > 40 || !page.items.every((item) => item.bookId === bookId() && item.fileId === fileId())) {
        throw new Error('Invalid bookmark response')
      }
      items.value = page.items
      nextCursor.value = page.nextCursor
      cursor = requested
      loaded.value = true
      return true
    } catch {
      if (turn === generation) error.value = true
      return false
    } finally {
      if (turn === generation) loading.value = false
    }
  }

  async function first() {
    if (await load(null)) history.value = []
  }
  async function older() {
    if (nextCursor.value === null) return
    const previous = cursor
    if (await load(nextCursor.value)) {
      history.value.push(previous)
      if (history.value.length > 32) history.value.shift()
    }
  }
  async function newer() {
    if (!history.value.length) return
    if (await load(history.value.at(-1) ?? null)) history.value.pop()
  }

  async function save(pageNumber: number, title: string) {
    if (loading.value || saving.value || !loaded.value) return
    const turn = generation
    saving.value = true
    error.value = false
    outcome.value = null
    try {
      const body: CreateFixedPageBookmarkPayload = { fileId: fileId(), pageNumber, title: title.trim() }
      const response = await api(`/api/v1/books/${bookId()}/bookmarks/fixed-page`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(body),
      })
      if (!response.ok) throw new Error('Bookmark request failed')
      const bookmark: BookmarkResponse = await response.json()
      if (turn !== generation) return
      if (
        bookmark.bookId !== bookId() ||
        bookmark.fileId !== fileId() ||
        bookmark.pageNumber !== pageNumber ||
        !Number.isSafeInteger(bookmark.id) ||
        bookmark.id <= 0 ||
        bookmark.cfi !== null ||
        bookmark.positionSeconds !== null
      )
        throw new Error('Invalid bookmark response')
      items.value = [bookmark]
      cursor = null
      nextCursor.value = null
      history.value = []
      loaded.value = false
      outcome.value = 'saved'
      saving.value = false
      await first()
      return bookmark
    } catch {
      if (turn === generation) error.value = true
    } finally {
      if (turn === generation) saving.value = false
    }
  }

  async function remove(bookmark: BookmarkResponse) {
    if (loading.value || saving.value || !items.value.some((item) => item.id === bookmark.id)) return
    const turn = generation
    saving.value = true
    error.value = false
    outcome.value = null
    try {
      const response = await api(`/api/v1/books/${bookId()}/bookmarks/${bookmark.id}`, { method: 'DELETE' })
      if (!response.ok) throw new Error('Bookmark request failed')
      if (turn !== generation) return
      items.value = items.value.filter((item) => item.id !== bookmark.id)
      outcome.value = 'removed'
      saving.value = false
      const refreshed = await load()
      if (refreshed && !items.value.length && hasPrevious.value) await newer()
    } catch {
      if (turn === generation) error.value = true
    } finally {
      if (turn === generation) saving.value = false
    }
  }

  function reset() {
    generation += 1
    controller?.abort()
    items.value = []
    history.value = []
    cursor = null
    nextCursor.value = null
    loading.value = false
    saving.value = false
    loaded.value = false
    error.value = false
    outcome.value = null
  }
  return {
    items,
    loading,
    saving,
    loaded,
    error,
    outcome,
    nextCursor,
    hasPrevious,
    hasAcknowledgedBookmark,
    load,
    first,
    older,
    newer,
    save,
    remove,
    reset,
  }
}
