import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import type { BrowseEntityItem, DuplicateCluster, DuplicateScanStatus, DismissedPairInfo } from '@bookorbit/types'

vi.mock('../api/entity-manager', () => ({
  listFileWriteRecovery: vi.fn<typeof entityManagerApi.listFileWriteRecovery>().mockResolvedValue([]),
  retryFileWrites: vi.fn<typeof entityManagerApi.retryFileWrites>(),
  getDuplicateScanStatus: vi.fn<(...args: unknown[]) => unknown>(),
  refreshDuplicates: vi.fn<(...args: unknown[]) => unknown>(),
  browseEntities: vi.fn<(...args: unknown[]) => unknown>(),
  mergeEntities: vi.fn<(...args: unknown[]) => unknown>(),
  renameEntity: vi.fn<(...args: unknown[]) => unknown>(),
  deleteEntity: vi.fn<(...args: unknown[]) => unknown>(),
  bulkDeleteEntities: vi.fn<(...args: unknown[]) => unknown>(),
  splitEntity: vi.fn<(...args: unknown[]) => unknown>(),
  scanDuplicates: vi.fn<(...args: unknown[]) => unknown>(),
  dismissPair: vi.fn<(...args: unknown[]) => unknown>(),
  undismissPair: vi.fn<(...args: unknown[]) => unknown>(),
  getDismissedPairsPage: vi.fn<(...args: unknown[]) => unknown>(),
  getEntityInfo: vi.fn<(...args: unknown[]) => unknown>(),
}))

import * as entityManagerApi from '../api/entity-manager'
import { useEntityManager } from './useEntityManager'

const mockGetDuplicateScanStatus = vi.mocked(entityManagerApi.getDuplicateScanStatus)
const mockRefreshDuplicates = vi.mocked(entityManagerApi.refreshDuplicates)
const mockBrowseEntities = vi.mocked(entityManagerApi.browseEntities)
const mockMergeEntities = vi.mocked(entityManagerApi.mergeEntities)
const mockRenameEntity = vi.mocked(entityManagerApi.renameEntity)
const mockDeleteEntity = vi.mocked(entityManagerApi.deleteEntity)
const mockBulkDeleteEntities = vi.mocked(entityManagerApi.bulkDeleteEntities)
const mockSplitEntity = vi.mocked(entityManagerApi.splitEntity)
const mockDismissPair = vi.mocked(entityManagerApi.dismissPair)
const mockUndismissPair = vi.mocked(entityManagerApi.undismissPair)
const mockGetDismissedPairs = vi.mocked(entityManagerApi.getDismissedPairsPage)

function makeStatus(state: DuplicateScanStatus['state']): DuplicateScanStatus {
  return { entityType: 'author', state, computedAt: null, totalPairs: null, threshold: null, progressPct: null }
}

function makeCluster(id: string, entityIds: (number | string)[]): DuplicateCluster {
  return {
    clusterId: id,
    entities: entityIds.map((eid) => ({ id: eid, name: `Entity ${eid}`, bookCount: 1, bookTitles: [] })),
    averageSimilarity: 0.9,
    suggestedTargetId: entityIds[0]!,
    pairDetails: [],
  }
}

function makeBrowseItem(id: number, name = `Item ${id}`): BrowseEntityItem {
  return { id, name, bookCount: 1 }
}

function makeBrowseResponse(items: BrowseEntityItem[], total = items.length) {
  return { items, total, page: 1, pageSize: 25 }
}

function makeDismissedPair(id: number, idA: number, idB: number): DismissedPairInfo {
  return {
    id,
    entityType: 'author',
    nameA: `Author ${idA}`,
    nameB: `Author ${idB}`,
    idA,
    idB,
    dismissedAt: '2024-01-01T00:00:00Z',
  }
}

describe('useEntityManager', () => {
  beforeEach(() => {
    vi.useFakeTimers()
    vi.resetAllMocks()
    mockGetDismissedPairs.mockResolvedValue({ items: [], total: 0, page: 1, pageSize: 20 })
  })

  afterEach(() => {
    vi.useRealTimers()
  })

  describe('fetchScanStatus()', () => {
    it('does not call getDuplicateScanStatus when isInline is true', async () => {
      const { entityType, fetchScanStatus } = useEntityManager()
      entityType.value = 'publisher'

      await fetchScanStatus()

      expect(mockGetDuplicateScanStatus).not.toHaveBeenCalled()
    })

    it('calls getDuplicateScanStatus for non-inline entity types', async () => {
      mockGetDuplicateScanStatus.mockResolvedValue(makeStatus('idle'))
      const { fetchScanStatus } = useEntityManager()

      await fetchScanStatus()

      expect(mockGetDuplicateScanStatus).toHaveBeenCalledWith('author')
    })

    it('sets poll timer when status.state is computing', async () => {
      mockGetDuplicateScanStatus.mockResolvedValue(makeStatus('computing'))
      const { fetchScanStatus, duplicateScanStatus } = useEntityManager()

      await fetchScanStatus()

      expect(duplicateScanStatus.value?.state).toBe('computing')

      mockGetDuplicateScanStatus.mockResolvedValue(makeStatus('done'))
      vi.advanceTimersByTime(3000)
      await Promise.resolve()
      await Promise.resolve()

      expect(mockGetDuplicateScanStatus).toHaveBeenCalledTimes(2)
    })

    it('triggers scan when status transitions from computing to done', async () => {
      mockGetDuplicateScanStatus.mockResolvedValueOnce(makeStatus('computing'))
      vi.mocked(entityManagerApi.scanDuplicates).mockResolvedValue({
        clusters: [],
        total: 0,
        page: 1,
        entityType: 'author',
        totalEntities: 0,
        pageSize: 20,
      })

      const { fetchScanStatus, duplicateScanStatus } = useEntityManager()
      await fetchScanStatus()
      expect(duplicateScanStatus.value?.state).toBe('computing')

      mockGetDuplicateScanStatus.mockResolvedValueOnce(makeStatus('done'))
      vi.advanceTimersByTime(3000)
      await Promise.resolve()
      await Promise.resolve()
      await Promise.resolve()

      expect(vi.mocked(entityManagerApi.scanDuplicates)).toHaveBeenCalled()
    })

    it('silently ignores errors', async () => {
      mockGetDuplicateScanStatus.mockRejectedValue(new Error('network error'))
      const { fetchScanStatus } = useEntityManager()

      await expect(fetchScanStatus()).resolves.toBeUndefined()
    })
  })

  describe('refreshDuplicates()', () => {
    it('calls entityManagerApi.refreshDuplicates with current minSimilarity', async () => {
      mockRefreshDuplicates.mockResolvedValue(makeStatus('idle'))
      const { refreshDuplicates, minSimilarity } = useEntityManager()
      minSimilarity.value = 0.7

      await refreshDuplicates()

      expect(mockRefreshDuplicates).toHaveBeenCalledWith('author', { minSimilarity: 0.7 })
    })

    it('starts poll timer when state is computing after refresh', async () => {
      mockRefreshDuplicates.mockResolvedValue(makeStatus('computing'))
      mockGetDuplicateScanStatus.mockResolvedValue(makeStatus('computing'))
      const { refreshDuplicates } = useEntityManager()

      await refreshDuplicates()

      vi.advanceTimersByTime(3000)
      await Promise.resolve()
      await Promise.resolve()

      expect(mockGetDuplicateScanStatus).toHaveBeenCalled()
    })

    it('does not start poll when state is not computing after refresh', async () => {
      mockRefreshDuplicates.mockResolvedValue(makeStatus('done'))
      const { refreshDuplicates } = useEntityManager()

      await refreshDuplicates()

      vi.advanceTimersByTime(5000)
      expect(mockGetDuplicateScanStatus).not.toHaveBeenCalled()
    })

    it('silently ignores errors', async () => {
      mockRefreshDuplicates.mockRejectedValue(new Error('fail'))
      const { refreshDuplicates } = useEntityManager()

      await expect(refreshDuplicates()).resolves.toBeUndefined()
    })
  })

  describe('removeClustersByIds()', () => {
    it('removes clusters containing matching entity ids', () => {
      const { clusters, removeClustersByIds } = useEntityManager()
      clusters.value = [makeCluster('c1', [1, 2]), makeCluster('c2', [3, 4]), makeCluster('c3', [5, 6])]

      removeClustersByIds([2])

      expect(clusters.value).toHaveLength(2)
      expect(clusters.value.map((c) => c.clusterId)).toEqual(['c2', 'c3'])
    })

    it('decrements scanTotal by number of removed clusters', () => {
      const { clusters, scanTotal, removeClustersByIds } = useEntityManager()
      clusters.value = [makeCluster('c1', [1, 2]), makeCluster('c2', [3, 4]), makeCluster('c3', [5, 6])]
      scanTotal.value = 3

      removeClustersByIds([1, 4])

      expect(scanTotal.value).toBe(1)
    })

    it('does not go below 0 for scanTotal', () => {
      const { clusters, scanTotal, removeClustersByIds } = useEntityManager()
      clusters.value = [makeCluster('c1', [1, 2])]
      scanTotal.value = 0

      removeClustersByIds([1])

      expect(scanTotal.value).toBe(0)
    })

    it('does nothing when no ids match', () => {
      const { clusters, scanTotal, removeClustersByIds } = useEntityManager()
      clusters.value = [makeCluster('c1', [1, 2])]
      scanTotal.value = 1

      removeClustersByIds([99])

      expect(clusters.value).toHaveLength(1)
      expect(scanTotal.value).toBe(1)
    })
  })

  describe('fetchBrowse()', () => {
    it('calls browseEntities and updates browseItems and browseTotal', async () => {
      const items = [makeBrowseItem(1), makeBrowseItem(2)]
      mockBrowseEntities.mockResolvedValue(makeBrowseResponse(items, 10))
      const { fetchBrowse, browseItems, browseTotal } = useEntityManager()

      await fetchBrowse()

      expect(mockBrowseEntities).toHaveBeenCalledWith(
        'author',
        expect.objectContaining({ page: 1, pageSize: 25, sortBy: 'name', sortOrder: 'asc', bookCount: 'any' }),
      )
      expect(browseItems.value).toEqual(items)
      expect(browseTotal.value).toBe(10)
    })

    it('sets browseLoading to false after successful fetch', async () => {
      mockBrowseEntities.mockResolvedValue(makeBrowseResponse([]))
      const { fetchBrowse, browseLoading } = useEntityManager()

      await fetchBrowse()

      expect(browseLoading.value).toBe(false)
    })

    it('resets browseItems and browseTotal to empty on error', async () => {
      mockBrowseEntities.mockRejectedValue(new Error('network error'))
      const { fetchBrowse, browseItems, browseTotal } = useEntityManager()

      await fetchBrowse()

      expect(browseItems.value).toEqual([])
      expect(browseTotal.value).toBe(0)
    })

    it('sets browseLoading to false even on error', async () => {
      mockBrowseEntities.mockRejectedValue(new Error('fail'))
      const { fetchBrowse, browseLoading } = useEntityManager()

      await fetchBrowse()

      expect(browseLoading.value).toBe(false)
    })

    it('updates selectedItemsMap for currently selected items', async () => {
      const items = [makeBrowseItem(1), makeBrowseItem(2)]
      mockBrowseEntities.mockResolvedValue(makeBrowseResponse(items))
      const { fetchBrowse, selectedIds, selectedItemsMap } = useEntityManager()
      selectedIds.value = new Set([1])

      await fetchBrowse()

      expect(selectedItemsMap.value.has(1)).toBe(true)
      expect(selectedItemsMap.value.has(2)).toBe(false)
    })

    it('passes search, sortBy, sortOrder parameters', async () => {
      mockBrowseEntities.mockResolvedValue(makeBrowseResponse([]))
      const { fetchBrowse, browseSearch, browseSortBy, browseSortOrder, browseBookCount } = useEntityManager()
      browseSearch.value = 'tolkien'
      browseSortBy.value = 'bookCount'
      browseSortOrder.value = 'desc'
      browseBookCount.value = 'empty'

      await fetchBrowse()

      expect(mockBrowseEntities).toHaveBeenCalledWith(
        'author',
        expect.objectContaining({ search: 'tolkien', sortBy: 'bookCount', sortOrder: 'desc', bookCount: 'empty' }),
      )
    })

    it('sends any book count filtering for inline entity types', async () => {
      mockBrowseEntities.mockResolvedValue(makeBrowseResponse([]))
      const { fetchBrowse, entityType, browseBookCount } = useEntityManager()
      entityType.value = 'publisher'
      browseBookCount.value = 'empty'

      await fetchBrowse()

      expect(mockBrowseEntities).toHaveBeenCalledWith('publisher', expect.objectContaining({ bookCount: 'any' }))
    })
  })

  describe('mergeEntities()', () => {
    it('calls entityManagerApi.mergeEntities with non-inline payload', async () => {
      mockMergeEntities.mockResolvedValue(undefined as never)
      const { mergeEntities } = useEntityManager()

      await mergeEntities(1, [2, 3], false)

      expect(mockMergeEntities).toHaveBeenCalledWith('author', {
        targetEntityId: 1,
        sourceEntityIds: [2, 3],
        writeFiles: false,
      })
    })

    it('calls entityManagerApi.mergeEntities with inline payload for inline entity type', async () => {
      mockMergeEntities.mockResolvedValue(undefined as never)
      const { mergeEntities, entityType } = useEntityManager()
      entityType.value = 'publisher'

      await mergeEntities('Pub A', ['Pub B', 'Pub C'], true)

      expect(mockMergeEntities).toHaveBeenCalledWith('publisher', {
        targetValue: 'Pub A',
        sourceValues: ['Pub B', 'Pub C'],
        writeFiles: true,
      })
    })

    it('sets operationLoading true during call and false after', async () => {
      let resolveOp!: () => void
      mockMergeEntities.mockImplementation(
        () =>
          new Promise<never>((r) => {
            resolveOp = r as () => void
          }),
      )
      const { mergeEntities, operationLoading } = useEntityManager()

      const op = mergeEntities(1, [2], false)
      expect(operationLoading.value).toBe(true)
      resolveOp()
      await op.catch(() => {})
      expect(operationLoading.value).toBe(false)
    })

    it('sets operationError and rethrows on failure', async () => {
      mockMergeEntities.mockRejectedValue(new Error('merge failed'))
      const { mergeEntities, operationError } = useEntityManager()

      await expect(mergeEntities(1, [2], false)).rejects.toThrow('merge failed')
      expect(operationError.value).toBe('merge failed')
    })

    it('clears operationError before each call', async () => {
      mockMergeEntities.mockRejectedValueOnce(new Error('first error')).mockResolvedValueOnce(undefined as never)
      const { mergeEntities, operationError } = useEntityManager()

      await mergeEntities(1, [2], false).catch(() => {})
      expect(operationError.value).toBe('first error')

      await mergeEntities(1, [2], false)
      expect(operationError.value).toBeNull()
    })
  })

  describe('renameEntity()', () => {
    it('calls entityManagerApi.renameEntity with non-inline payload', async () => {
      mockRenameEntity.mockResolvedValue(undefined as never)
      const { renameEntity } = useEntityManager()

      await renameEntity(5, 'New Name', true)

      expect(mockRenameEntity).toHaveBeenCalledWith('author', { entityId: 5, newName: 'New Name', writeFiles: true })
    })

    it('calls entityManagerApi.renameEntity with inline payload', async () => {
      mockRenameEntity.mockResolvedValue(undefined as never)
      const { renameEntity, entityType } = useEntityManager()
      entityType.value = 'language'

      await renameEntity('en', 'English', false)

      expect(mockRenameEntity).toHaveBeenCalledWith('language', { currentValue: 'en', newName: 'English', writeFiles: false })
    })

    it('sets operationError and rethrows on failure', async () => {
      mockRenameEntity.mockRejectedValue(new Error('rename failed'))
      const { renameEntity, operationError } = useEntityManager()

      await expect(renameEntity(1, 'foo', false)).rejects.toThrow('rename failed')
      expect(operationError.value).toBe('rename failed')
    })
  })

  describe('deleteEntity()', () => {
    it('calls entityManagerApi.deleteEntity with non-inline payload', async () => {
      mockDeleteEntity.mockResolvedValue(undefined as never)
      const { deleteEntity } = useEntityManager()

      await deleteEntity(7, 'soft', false)

      expect(mockDeleteEntity).toHaveBeenCalledWith('author', { entityId: 7, mode: 'soft', writeFiles: false })
    })

    it('calls entityManagerApi.deleteEntity with inline payload (mode forced to inline)', async () => {
      mockDeleteEntity.mockResolvedValue(undefined as never)
      const { deleteEntity, entityType } = useEntityManager()
      entityType.value = 'publisher'

      await deleteEntity('Pub X', 'hard', true)

      expect(mockDeleteEntity).toHaveBeenCalledWith('publisher', { value: 'Pub X', mode: 'inline', writeFiles: true })
    })

    it('sets operationError and rethrows on failure', async () => {
      mockDeleteEntity.mockRejectedValue(new Error('delete failed'))
      const { deleteEntity, operationError } = useEntityManager()

      await expect(deleteEntity(1, 'hard', false)).rejects.toThrow('delete failed')
      expect(operationError.value).toBe('delete failed')
    })
  })

  describe('bulkDeleteEntities()', () => {
    it('calls entityManagerApi.bulkDeleteEntities with non-inline payload', async () => {
      mockBulkDeleteEntities.mockResolvedValue(undefined as never)
      const { bulkDeleteEntities } = useEntityManager()

      await bulkDeleteEntities([1, 2, 3], 'hard', false)

      expect(mockBulkDeleteEntities).toHaveBeenCalledWith('author', { entityIds: [1, 2, 3], mode: 'hard', writeFiles: false })
    })

    it('calls entityManagerApi.bulkDeleteEntities with inline payload', async () => {
      mockBulkDeleteEntities.mockResolvedValue(undefined as never)
      const { bulkDeleteEntities, entityType } = useEntityManager()
      entityType.value = 'publisher'

      await bulkDeleteEntities(['Pub A', 'Pub B'], 'soft', true)

      expect(mockBulkDeleteEntities).toHaveBeenCalledWith('publisher', {
        values: ['Pub A', 'Pub B'],
        mode: 'inline',
        writeFiles: true,
      })
    })

    it('sets operationError and rethrows on failure', async () => {
      mockBulkDeleteEntities.mockRejectedValue(new Error('bulk delete failed'))
      const { bulkDeleteEntities, operationError } = useEntityManager()

      await expect(bulkDeleteEntities([1], 'soft', false)).rejects.toThrow('bulk delete failed')
      expect(operationError.value).toBe('bulk delete failed')
    })
  })

  describe('splitEntity()', () => {
    it('calls entityManagerApi.splitEntity with correct payload', async () => {
      mockSplitEntity.mockResolvedValue(undefined as never)
      const { splitEntity } = useEntityManager()

      await splitEntity(10, ['Part A', 'Part B'], true)

      expect(mockSplitEntity).toHaveBeenCalledWith('author', { entityId: 10, newNames: ['Part A', 'Part B'], writeFiles: true })
    })

    it('sets operationError and rethrows on failure', async () => {
      mockSplitEntity.mockRejectedValue(new Error('split failed'))
      const { splitEntity, operationError } = useEntityManager()

      await expect(splitEntity(1, ['A', 'B'], false)).rejects.toThrow('split failed')
      expect(operationError.value).toBe('split failed')
    })

    it('sets operationLoading to false after failure', async () => {
      mockSplitEntity.mockRejectedValue(new Error('fail'))
      const { splitEntity, operationLoading } = useEntityManager()

      await splitEntity(1, ['A', 'B'], false).catch(() => {})
      expect(operationLoading.value).toBe(false)
    })
  })

  describe('dismissPair()', () => {
    it('calls entityManagerApi.dismissPair with non-inline payload', async () => {
      mockDismissPair.mockResolvedValue(undefined as never)
      mockGetDismissedPairs.mockResolvedValue({ items: [], total: 0, page: 1, pageSize: 20 })
      const { dismissPair } = useEntityManager()

      await dismissPair(1, 2, 'not a duplicate')

      expect(mockDismissPair).toHaveBeenCalledWith('author', {
        entityIdA: 1,
        entityIdB: 2,
        reason: 'not a duplicate',
      })
    })

    it('calls entityManagerApi.dismissPair with inline payload', async () => {
      mockDismissPair.mockResolvedValue(undefined as never)
      mockGetDismissedPairs.mockResolvedValue({ items: [], total: 0, page: 1, pageSize: 20 })
      const { dismissPair, entityType } = useEntityManager()
      entityType.value = 'publisher'

      await dismissPair('Pub A', 'Pub B')

      expect(mockDismissPair).toHaveBeenCalledWith('publisher', {
        valueA: 'Pub A',
        valueB: 'Pub B',
        reason: undefined,
      })
    })

    it('refreshes dismissed pairs after dismissing', async () => {
      mockDismissPair.mockResolvedValue(undefined as never)
      const pair = makeDismissedPair(99, 1, 2)
      mockGetDismissedPairs.mockResolvedValue({ items: [pair], total: 1, page: 1, pageSize: 20 })
      const { dismissPair, dismissedPairs } = useEntityManager()

      await dismissPair(1, 2)

      expect(dismissedPairs.value).toEqual([pair])
    })
  })

  describe('undismissPair()', () => {
    it('calls entityManagerApi.undismissPair with non-inline payload', async () => {
      mockUndismissPair.mockResolvedValue(undefined as never)
      mockGetDismissedPairs.mockResolvedValue({ items: [], total: 0, page: 1, pageSize: 20 })
      const { undismissPair } = useEntityManager()

      await undismissPair(3, 4)

      expect(mockUndismissPair).toHaveBeenCalledWith('author', {
        entityIdA: 3,
        entityIdB: 4,
      })
    })

    it('calls entityManagerApi.undismissPair with inline payload', async () => {
      mockUndismissPair.mockResolvedValue(undefined as never)
      mockGetDismissedPairs.mockResolvedValue({ items: [], total: 0, page: 1, pageSize: 20 })
      const { undismissPair, entityType } = useEntityManager()
      entityType.value = 'language'

      await undismissPair('en', 'eng')

      expect(mockUndismissPair).toHaveBeenCalledWith('language', {
        valueA: 'en',
        valueB: 'eng',
      })
    })

    it('refreshes dismissed pairs after undismissing', async () => {
      mockUndismissPair.mockResolvedValue(undefined as never)
      mockGetDismissedPairs.mockResolvedValue({ items: [], total: 0, page: 1, pageSize: 20 })
      const { undismissPair, dismissedPairs } = useEntityManager()

      await undismissPair(1, 2)

      expect(mockGetDismissedPairs).toHaveBeenCalled()
      expect(dismissedPairs.value).toEqual([])
    })
  })

  describe('fetchDismissedPairs()', () => {
    it('calls getDismissedPairs and updates dismissedPairs', async () => {
      const pairs = [makeDismissedPair(1, 10, 20)]
      mockGetDismissedPairs.mockResolvedValue({ items: pairs, total: pairs.length, page: 1, pageSize: 20 })
      const { fetchDismissedPairs, dismissedPairs } = useEntityManager()

      await fetchDismissedPairs()

      expect(mockGetDismissedPairs).toHaveBeenCalledWith('author', { page: 1, pageSize: 20 }, expect.any(AbortSignal))
      expect(dismissedPairs.value).toEqual(pairs)
    })

    it('sets dismissedPairs to empty array on error', async () => {
      mockGetDismissedPairs.mockRejectedValue(new Error('fetch error'))
      const { fetchDismissedPairs, dismissedPairs } = useEntityManager()

      await fetchDismissedPairs()

      expect(dismissedPairs.value).toEqual([])
    })

    it('sets dismissedLoading to false after success', async () => {
      mockGetDismissedPairs.mockResolvedValue({ items: [], total: 0, page: 1, pageSize: 20 })
      const { fetchDismissedPairs, dismissedLoading } = useEntityManager()

      await fetchDismissedPairs()

      expect(dismissedLoading.value).toBe(false)
    })

    it('sets dismissedLoading to false after error', async () => {
      mockGetDismissedPairs.mockRejectedValue(new Error('fail'))
      const { fetchDismissedPairs, dismissedLoading } = useEntityManager()

      await fetchDismissedPairs()

      expect(dismissedLoading.value).toBe(false)
    })
  })

  describe('selection mechanics', () => {
    describe('toggleSelection()', () => {
      it('adds an id to selectedIds when not selected', () => {
        const { toggleSelection, selectedIds } = useEntityManager()

        toggleSelection(1)

        expect(selectedIds.value.has(1)).toBe(true)
      })

      it('removes an id from selectedIds when already selected', () => {
        const { toggleSelection, selectedIds } = useEntityManager()

        toggleSelection(1)
        toggleSelection(1)

        expect(selectedIds.value.has(1)).toBe(false)
      })
    })

    describe('removeFromSelection()', () => {
      it('removes a selected id', () => {
        const { toggleSelection, removeFromSelection, selectedIds } = useEntityManager()

        toggleSelection(5)
        removeFromSelection(5)

        expect(selectedIds.value.has(5)).toBe(false)
      })

      it('does nothing when id is not selected', () => {
        const { removeFromSelection, selectedIds } = useEntityManager()

        removeFromSelection(99)

        expect(selectedIds.value.size).toBe(0)
      })
    })

    describe('clearSelection()', () => {
      it('clears all selected ids', () => {
        const { toggleSelection, clearSelection, selectedIds } = useEntityManager()

        toggleSelection(1)
        toggleSelection(2)
        clearSelection()

        expect(selectedIds.value.size).toBe(0)
      })

      it('clears selectedItemsMap', () => {
        const { toggleSelection, clearSelection, selectedItemsMap } = useEntityManager()

        toggleSelection(1)
        clearSelection()

        expect(selectedItemsMap.value.size).toBe(0)
      })
    })

    describe('rangeSelectTo()', () => {
      it('toggles single item when no anchor is set', () => {
        const { rangeSelectTo, selectedIds } = useEntityManager()

        rangeSelectTo(3)

        expect(selectedIds.value.has(3)).toBe(true)
      })

      it('selects a range of items based on anchor', async () => {
        mockBrowseEntities.mockResolvedValue(makeBrowseResponse([makeBrowseItem(1), makeBrowseItem(2), makeBrowseItem(3), makeBrowseItem(4)], 4))
        const { fetchBrowse, toggleSelection, rangeSelectTo, selectedIds } = useEntityManager()
        await fetchBrowse()

        toggleSelection(1)
        rangeSelectTo(3)

        expect(selectedIds.value.has(1)).toBe(true)
        expect(selectedIds.value.has(2)).toBe(true)
        expect(selectedIds.value.has(3)).toBe(true)
        expect(selectedIds.value.has(4)).toBe(false)
      })

      it('falls back to toggle when anchor or target not in browseItems', () => {
        const { toggleSelection, rangeSelectTo, selectedIds } = useEntityManager()

        toggleSelection(1)
        rangeSelectTo(99)

        expect(selectedIds.value.has(99)).toBe(true)
      })
    })
  })

  describe('clearBrowse()', () => {
    it('resets browseItems and browseTotal', async () => {
      mockBrowseEntities.mockResolvedValue(makeBrowseResponse([makeBrowseItem(1)], 5))
      const { fetchBrowse, clearBrowse, browseItems, browseTotal } = useEntityManager()
      await fetchBrowse()

      clearBrowse()

      expect(browseItems.value).toEqual([])
      expect(browseTotal.value).toBe(0)
    })

    it('resets browsePage to 1', async () => {
      mockBrowseEntities.mockResolvedValue(makeBrowseResponse([]))
      const { fetchBrowse, clearBrowse, browsePage } = useEntityManager()
      browsePage.value = 3
      await fetchBrowse()

      clearBrowse()

      expect(browsePage.value).toBe(1)
    })
  })

  describe('clearScan()', () => {
    it('resets clusters, scanError, hasScanned, scanPage, scanTotal', () => {
      const { clusters, scanError, hasScanned, scanPage, scanTotal, clearScan } = useEntityManager()
      clusters.value = [makeCluster('c1', [1])]
      scanError.value = 'some error'
      hasScanned.value = true
      scanPage.value = 5
      scanTotal.value = 10

      clearScan()

      expect(clusters.value).toEqual([])
      expect(scanError.value).toBeNull()
      expect(hasScanned.value).toBe(false)
      expect(scanPage.value).toBe(1)
      expect(scanTotal.value).toBe(0)
    })
  })

  describe('entityType watch', () => {
    it('clears scan and browse state when entityType changes', async () => {
      mockBrowseEntities.mockResolvedValue(makeBrowseResponse([makeBrowseItem(1)], 5))
      const { fetchBrowse, entityType, browseItems, browseTotal, duplicateScanStatus } = useEntityManager()

      mockGetDuplicateScanStatus.mockResolvedValue(makeStatus('done'))
      await fetchBrowse()

      entityType.value = 'genre'
      await Promise.resolve()

      expect(browseItems.value).toEqual([])
      expect(browseTotal.value).toBe(0)
      expect(duplicateScanStatus.value).toBeNull()
    })
  })
})
