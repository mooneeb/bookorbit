import { computed, ref, watch, type Ref } from 'vue'
import type { DuplicateCluster } from '@bookorbit/types'

export function useDuplicateMergeSelection(cluster: Ref<DuplicateCluster>) {
  const selectedTargetId = ref<number | string>(cluster.value.suggestedTargetId)
  const includedIds = ref(new Set<number | string>())
  const previewing = ref(false)
  const writeFiles = ref(false)
  const sortedEntities = computed(() => [...cluster.value.entities].sort((a, b) => b.bookCount - a.bookCount))
  const sourceEntities = computed(() =>
    cluster.value.entities.filter((entity) => includedIds.value.has(entity.id) && entity.id !== selectedTargetId.value),
  )
  const sourceIds = computed(() => sourceEntities.value.map((entity) => entity.id))
  const targetEntity = computed(() => cluster.value.entities.find((entity) => entity.id === selectedTargetId.value))
  const completeGroup = computed(
    () =>
      (cluster.value.entityTotal ?? cluster.value.entities.length) === cluster.value.entities.length &&
      (cluster.value.pairTotal ?? cluster.value.pairDetails.length) === cluster.value.pairDetails.length,
  )

  watch(
    cluster,
    () => {
      selectedTargetId.value = cluster.value.suggestedTargetId
      includedIds.value = new Set(completeGroup.value ? cluster.value.entities.map((entity) => entity.id) : [selectedTargetId.value])
      previewing.value = false
    },
    { immediate: true },
  )

  function selectTarget(id: number | string): void {
    selectedTargetId.value = id
    includedIds.value = new Set([...includedIds.value, id])
    previewing.value = false
  }

  function toggleSource(id: number | string): void {
    const next = new Set(includedIds.value)
    if (next.has(id)) next.delete(id)
    else next.add(id)
    includedIds.value = next
    previewing.value = false
  }

  function showPreview(): void {
    if (sourceIds.value.length > 0 && targetEntity.value) previewing.value = true
  }

  function cancelPreview(): void {
    previewing.value = false
  }

  return {
    selectedTargetId,
    sortedEntities,
    sourceEntities,
    sourceIds,
    targetEntity,
    completeGroup,
    previewing,
    writeFiles,
    selectTarget,
    toggleSource,
    showPreview,
    cancelPreview,
  }
}
