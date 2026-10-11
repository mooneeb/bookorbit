import { api } from '@/lib/api'
import type {
  BrowseEntitiesParams,
  BrowseEntitiesResponse,
  BulkDeleteResult,
  DeleteResult,
  DismissedPairInfo,
  EntityDismissedPairsPage,
  EntityDuplicateClusterPage,
  DuplicateScanResponse,
  DuplicateScanStatus,
  EntityInfo,
  EntityType,
  MergeResult,
  RenameResult,
  SplitResult,
} from '@bookorbit/types'

function toQuery(params: Record<string, string | number | undefined>): string {
  const entries = Object.entries(params).filter(([, v]) => v !== undefined)
  if (entries.length === 0) return ''
  return '?' + new URLSearchParams(entries.map(([k, v]) => [k, String(v)])).toString()
}

const BASE = '/api/v1/entity-manager'

export async function browseEntities(entityType: EntityType, params: BrowseEntitiesParams): Promise<BrowseEntitiesResponse> {
  const query = toQuery({
    search: params.search,
    page: params.page,
    pageSize: params.pageSize,
    sortBy: params.sortBy,
    sortOrder: params.sortOrder,
    bookCount: params.bookCount,
  })
  const res = await api(`${BASE}/${entityType}/browse${query}`)
  if (!res.ok) throw new Error(`Failed to browse ${entityType}`)
  return res.json()
}

export async function scanDuplicates(
  entityType: EntityType,
  params: { libraryId?: number; minSimilarity?: number; page?: number; pageSize?: number },
  signal?: AbortSignal,
): Promise<DuplicateScanResponse> {
  const query = toQuery({ libraryId: params.libraryId, minSimilarity: params.minSimilarity, page: params.page, pageSize: params.pageSize })
  const res = await api(`${BASE}/${entityType}/duplicates/scan${query}`, { signal })
  if (!res.ok) throw new Error(`Failed to scan ${entityType} duplicates`)
  return res.json()
}

export async function mergeEntities(
  entityType: EntityType,
  payload: { targetEntityId?: number; targetValue?: string; sourceEntityIds?: number[]; sourceValues?: string[]; writeFiles?: boolean },
): Promise<MergeResult> {
  const res = await api(`${BASE}/${entityType}/merge`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(payload),
  })
  if (!res.ok) throw new Error(`Failed to merge ${entityType}`)
  return res.json()
}

export async function getDuplicateClusterPage(
  entityType: EntityType,
  params: { clusterId: string; page: number; pageSize: number },
  signal?: AbortSignal,
): Promise<EntityDuplicateClusterPage> {
  const res = await api(`${BASE}/${entityType}/duplicates/cluster${toQuery(params)}`, { signal })
  if (!res.ok) throw new Error(`Failed to get ${entityType} duplicate group page`)
  return res.json()
}

export async function renameEntity(
  entityType: EntityType,
  payload: { entityId?: number; currentValue?: string; newName: string; writeFiles?: boolean },
): Promise<RenameResult> {
  const res = await api(`${BASE}/${entityType}/rename`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(payload),
  })
  if (!res.ok) throw new Error(`Failed to rename ${entityType}`)
  return res.json()
}

export async function deleteEntity(
  entityType: EntityType,
  payload: { entityId?: number; value?: string; mode?: 'soft' | 'hard' | 'inline'; writeFiles?: boolean },
): Promise<DeleteResult> {
  const res = await api(`${BASE}/${entityType}/delete`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(payload),
  })
  if (!res.ok) throw new Error(`Failed to delete ${entityType}`)
  return res.json()
}

export async function bulkDeleteEntities(
  entityType: EntityType,
  payload: { entityIds?: number[]; values?: string[]; mode?: 'soft' | 'hard' | 'inline'; writeFiles?: boolean },
): Promise<BulkDeleteResult> {
  const res = await api(`${BASE}/${entityType}/bulk-delete`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(payload),
  })
  if (!res.ok) throw new Error(`Failed to bulk delete ${entityType}`)
  return res.json()
}

export async function splitEntity(
  entityType: EntityType,
  payload: { entityId: number; newNames: string[]; writeFiles?: boolean },
): Promise<SplitResult> {
  const res = await api(`${BASE}/${entityType}/split`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(payload),
  })
  if (!res.ok) throw new Error(`Failed to split ${entityType}`)
  return res.json()
}

export async function dismissPair(
  entityType: EntityType,
  payload: { entityIdA?: number; entityIdB?: number; valueA?: string; valueB?: string; reason?: string },
): Promise<void> {
  const res = await api(`${BASE}/${entityType}/duplicates/dismiss`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(payload),
  })
  if (!res.ok) throw new Error(`Failed to dismiss ${entityType} duplicate pair`)
}

export async function undismissPair(
  entityType: EntityType,
  payload: { entityIdA?: number; entityIdB?: number; valueA?: string; valueB?: string },
): Promise<void> {
  const res = await api(`${BASE}/${entityType}/duplicates/undismiss`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(payload),
  })
  if (!res.ok) throw new Error(`Failed to undismiss ${entityType} duplicate pair`)
}

export async function getDismissedPairs(entityType: EntityType): Promise<DismissedPairInfo[]> {
  const res = await api(`${BASE}/${entityType}/duplicates/dismissed`)
  if (!res.ok) throw new Error(`Failed to get dismissed ${entityType} pairs`)
  return res.json()
}

export async function getDismissedPairsPage(
  entityType: EntityType,
  params: { page: number; pageSize: number },
  signal?: AbortSignal,
): Promise<EntityDismissedPairsPage> {
  const res = await api(`${BASE}/${entityType}/duplicates/dismissed-page${toQuery(params)}`, { signal })
  if (!res.ok) throw new Error(`Failed to get dismissed ${entityType} pairs`)
  return res.json()
}

export async function getDuplicateScanStatus(entityType: EntityType): Promise<DuplicateScanStatus> {
  const res = await api(`${BASE}/${entityType}/duplicates/status`)
  if (!res.ok) throw new Error(`Failed to get ${entityType} duplicate scan status`)
  return res.json()
}

export async function refreshDuplicates(entityType: EntityType, params?: { minSimilarity?: number }): Promise<DuplicateScanStatus> {
  const res = await api(`${BASE}/${entityType}/duplicates/refresh`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(params ?? {}),
  })
  if (!res.ok) throw new Error(`Failed to refresh ${entityType} duplicates`)
  return res.json()
}

export async function getEntityInfo(entityType: EntityType, entityId: number | string): Promise<EntityInfo> {
  const res = await api(`${BASE}/${entityType}/info/${entityId}`)
  if (!res.ok) throw new Error(`Failed to get ${entityType} info`)
  return res.json()
}
