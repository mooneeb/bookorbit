import { computed, ref } from 'vue'
import type { HardcoverImportApplyResult, HardcoverImportPreview } from '@bookorbit/types'
import { applyHardcoverImport, previewHardcoverImport } from '../api/hardcover.api'

const preview = ref<HardcoverImportPreview | null>(null)
const result = ref<HardcoverImportApplyResult | null>(null)
const previewing = ref(false)
const applying = ref(false)
const error = ref<string | null>(null)
const afterId = ref(0)
const nextCursor = ref<number | null>(null)

const hasPreview = computed(() => preview.value !== null)
const canApply = computed(
  () => ((preview.value?.summary.willUpdate ?? 0) > 0 || (preview.value?.summary.needsReview ?? 0) > 0) && !previewing.value && !applying.value,
)

export function useHardcoverImport() {
  async function loadPreview(cursor = 0): Promise<void> {
    previewing.value = true
    error.value = null
    result.value = null
    try {
      preview.value = await previewHardcoverImport(cursor === 0 ? undefined : cursor)
      afterId.value = cursor
      nextCursor.value = preview.value.nextCursor ?? null
    } catch (err) {
      error.value = err instanceof Error ? err.message : 'Failed to preview Hardcover import'
    } finally {
      previewing.value = false
    }
  }

  async function applyPreview(hardcoverUserBookIds?: number[], importProgress = false): Promise<HardcoverImportApplyResult | null> {
    applying.value = true
    error.value = null
    try {
      result.value = await applyHardcoverImport({
        ...(hardcoverUserBookIds ? { hardcoverUserBookIds } : {}),
        importProgress,
        ...(afterId.value > 0 ? { afterId: afterId.value } : {}),
      })
      preview.value = null
      return result.value
    } catch (err) {
      error.value = err instanceof Error ? err.message : 'Failed to import Hardcover read status'
      return null
    } finally {
      applying.value = false
    }
  }

  async function loadNextPage(): Promise<void> {
    if (nextCursor.value != null) await loadPreview(nextCursor.value)
  }

  function clearImport(): void {
    afterId.value = 0
    nextCursor.value = null
    preview.value = null
    result.value = null
    error.value = null
  }

  return {
    preview,
    result,
    previewing,
    applying,
    error,
    nextCursor,
    hasPreview,
    canApply,
    loadPreview,
    loadNextPage,
    applyPreview,
    clearImport,
  }
}
