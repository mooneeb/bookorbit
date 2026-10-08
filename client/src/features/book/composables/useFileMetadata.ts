import { ref } from 'vue'
import { api } from '@/lib/api'
import type { BookFileMetadataResponse } from '@bookorbit/types'

export type FileMetadata = BookFileMetadataResponse

export function useFileMetadata() {
  const loading = ref(false)

  async function loadFromFile(bookId: number): Promise<FileMetadata | null> {
    loading.value = true
    try {
      const res = await api(`/api/v1/books/${bookId}/metadata-from-file`)
      if (!res.ok) return null
      return (await res.json()) as FileMetadata
    } catch {
      return null
    } finally {
      loading.value = false
    }
  }

  return { loading, loadFromFile }
}
