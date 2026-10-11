import { computed, onUnmounted, ref, watch, type Ref } from 'vue'
import type { DuplicateCluster, EntityDuplicateClusterPage, EntityType } from '@bookorbit/types'
import { getDuplicateClusterPage } from '../../api/entity-manager'

export function useDuplicateClusterPage(entityType: Ref<EntityType>, cluster: Ref<DuplicateCluster | null>) {
  const details = ref<EntityDuplicateClusterPage | null>(null)
  const loading = ref(false)
  const error = ref<string | null>(null)
  let controller: AbortController | null = null

  const currentCluster = computed<DuplicateCluster | null>(() => {
    if (!cluster.value) return null
    if (!details.value) return cluster.value
    return {
      ...cluster.value,
      ...details.value,
      detailsPageSize: details.value.pageSize,
      suggestedTargetId: details.value.entities[0]?.id ?? cluster.value.suggestedTargetId,
    }
  })
  const page = computed(() => details.value?.page ?? 1)
  const totalPages = computed(() => {
    const item = currentCluster.value
    if (!item) return 1
    return Math.max(
      1,
      Math.ceil(Math.max(item.entityTotal ?? item.entities.length, item.pairTotal ?? item.pairDetails.length) / (item.detailsPageSize ?? 10)),
    )
  })

  watch([cluster, entityType], () => {
    controller?.abort()
    details.value = null
    loading.value = false
    error.value = null
  })
  onUnmounted(() => controller?.abort())

  async function fetchPage(nextPage: number): Promise<void> {
    if (!cluster.value || nextPage < 1 || nextPage > totalPages.value) return
    controller?.abort()
    const request = new AbortController()
    controller = request
    loading.value = true
    error.value = null
    try {
      const result = await getDuplicateClusterPage(
        entityType.value,
        { clusterId: cluster.value.clusterId, page: nextPage, pageSize: cluster.value.detailsPageSize ?? 10 },
        request.signal,
      )
      if (!request.signal.aborted) details.value = result
    } catch (cause) {
      if (!request.signal.aborted) error.value = cause instanceof Error ? cause.message : 'Failed to load group'
    } finally {
      if (!request.signal.aborted) loading.value = false
    }
  }

  return { currentCluster, page, totalPages, loading, error, fetchPage }
}
