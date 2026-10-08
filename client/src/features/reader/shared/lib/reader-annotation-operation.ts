import type {
  AnnotationItem,
  NativeAnnotationOperation,
  NativeAnnotationOperationsRequest,
  NativeAnnotationOperationsResponse,
} from '@bookorbit/types'
import { api } from '@/lib/api'

export async function applyReaderAnnotationOperation(
  bookId: number,
  annotationId: number,
  baseVersion: number,
  clientId: string | null | undefined,
  action: 'update' | 'delete',
  payload?: NativeAnnotationOperation['payload'],
): Promise<AnnotationItem | null> {
  const operationId = crypto.randomUUID()
  const request: NativeAnnotationOperationsRequest = {
    deviceId: 'web-reader',
    operations: [
      { operationId, clientId: clientId ?? crypto.randomUUID(), annotationId, bookId, baseVersion, action, ...(payload ? { payload } : {}) },
    ],
  }
  try {
    const response = await api('/api/v1/annotations/native/operations', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(request),
    })
    if (!response.ok) return null
    const result: NativeAnnotationOperationsResponse = await response.json()
    const operation = result.results.find((item) => item.operationId === operationId)
    return operation?.status === 'applied' ? (operation.annotation ?? null) : null
  } catch {
    return null
  }
}
