import { computed, ref, watch, type Ref } from 'vue'
import type { DuplicateCluster } from '@bookorbit/types'

import { clusterKey } from '../utils/duplicate-cluster'

/**
 * Tracks which cluster the compare panel is showing. When the active cluster leaves the list,
 * because it was merged or dismissed, the next one takes over so reviewing flows without a
 * manual reselect.
 */
export function useDuplicateReview(clusters: Ref<DuplicateCluster[]>) {
  const activeKey = ref<string | null>(null)
  const keepListOpen = ref(false)

  const activeCluster = computed(() => clusters.value.find((cluster) => clusterKey(cluster) === activeKey.value) ?? null)

  watch(
    clusters,
    (list) => {
      if (list.length === 0) {
        activeKey.value = null
        return
      }
      if (keepListOpen.value) return
      if (!list.some((cluster) => clusterKey(cluster) === activeKey.value)) {
        activeKey.value = clusterKey(list[0]!)
      }
    },
    { immediate: true },
  )

  function selectCluster(key: string): void {
    keepListOpen.value = false
    activeKey.value = key
  }

  function clearSelection(): void {
    keepListOpen.value = true
    activeKey.value = null
  }

  return { activeKey, activeCluster, selectCluster, clearSelection }
}
