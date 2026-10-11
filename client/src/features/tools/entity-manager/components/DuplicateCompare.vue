<script setup lang="ts">
import { computed, toRef } from 'vue'
import { useI18n } from 'vue-i18n'
import { ArrowLeft, Check, GitMerge, UserMinus, X } from '@lucide/vue'
import { Permission, type ClusterEntity, type DuplicateCluster } from '@bookorbit/types'
import { metadataScoreColor } from '@/lib/metadata-score-color'
import ToggleSwitch from '@/components/ui/ToggleSwitch.vue'
import ConfirmDialog from '@/components/ui/ConfirmDialog.vue'
import { usePermissions } from '@/features/auth/composables/usePermissions'
import { useDuplicateMergeSelection } from '../composables/useDuplicateMergeSelection'

const props = withDefaults(
  defineProps<{
    cluster: DuplicateCluster
    operationLoading: boolean
    page?: number
    totalPages?: number
    detailLoading?: boolean
    detailError?: string | null
  }>(),
  { page: 1, totalPages: 1, detailLoading: false, detailError: null },
)

const emit = defineEmits<{
  merge: [targetId: number | string, sourceIds: (number | string)[], writeFiles: boolean]
  dismissEntity: [entityId: number | string]
  dismissPair: [idA: number | string, idB: number | string]
  dismissCluster: []
  back: []
  'update:page': [value: number]
}>()

const { t } = useI18n()
const { hasPermission } = usePermissions()
const canEdit = computed(() => hasPermission(Permission.LibraryEditMetadata))
const {
  writeFiles,
  selectedTargetId,
  sortedEntities,
  sourceEntities,
  sourceIds,
  targetEntity,
  completeGroup,
  previewing,
  selectTarget,
  toggleSource,
  showPreview,
  cancelPreview,
} = useDuplicateMergeSelection(toRef(props, 'cluster'))
const similarityPercent = computed(() => Math.round(props.cluster.averageSimilarity * 100))
const entityTotal = computed(() => props.cluster.entityTotal ?? props.cluster.entities.length)
const pairTotal = computed(() => props.cluster.pairTotal ?? props.cluster.pairDetails.length)
const busy = computed(() => props.operationLoading || props.detailLoading)
const similarityStyle = computed<Record<string, string>>(() => {
  const color = metadataScoreColor(similarityPercent.value)
  return { color, backgroundColor: `color-mix(in oklch, ${color} 14%, transparent)` }
})

function entityName(id: number | string): string {
  return props.cluster.entities.find((entity) => entity.id === id)?.name ?? t('tools.entityManager.unknown')
}

function pairPercent(similarity: number): number {
  return Math.round(similarity * 100)
}

function pairStyle(similarity: number): Record<string, string> {
  const color = metadataScoreColor(pairPercent(similarity))
  return { color, backgroundColor: `color-mix(in oklch, ${color} 14%, transparent)` }
}

function handleSelectTarget(entity: ClusterEntity): void {
  selectTarget(entity.id)
}

function handleToggleSource(entity: ClusterEntity): void {
  toggleSource(entity.id)
}

function handleDismissEntity(id: number | string): void {
  if (canEdit.value && completeGroup.value && !busy.value) emit('dismissEntity', id)
}

function handleDismissPair(idA: number | string, idB: number | string): void {
  if (canEdit.value && !busy.value) emit('dismissPair', idA, idB)
}

function handleDismissCluster(): void {
  if (canEdit.value && !busy.value) emit('dismissCluster')
}

function handleMerge(): void {
  if (canEdit.value && previewing.value && !busy.value && sourceIds.value.length > 0 && targetEntity.value)
    emit('merge', selectedTargetId.value, sourceIds.value, writeFiles.value)
}

function handleBack(): void {
  emit('back')
}

function handlePreviousPage(): void {
  emit('update:page', props.page - 1)
}

function handleNextPage(): void {
  emit('update:page', props.page + 1)
}
</script>

<template>
  <div class="flex min-h-0 flex-1 flex-col">
    <div class="flex flex-none items-center gap-3 border-b border-border px-5 py-3">
      <button
        type="button"
        class="grid size-8 shrink-0 place-items-center rounded-md text-muted-foreground transition-colors hover:bg-accent hover:text-foreground focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring md:hidden"
        :aria-label="t('tools.entityManager.duplicates.backToList')"
        @click="handleBack"
      >
        <ArrowLeft :size="16" aria-hidden="true" />
      </button>
      <p id="duplicate-compare-hint" class="min-w-0 flex-1 truncate text-sm font-semibold text-foreground">
        {{ t('tools.entityManager.duplicates.chooseSelectedHint') }}
      </p>
      <span class="shrink-0 rounded-full px-2.5 py-1 text-xs font-semibold tabular-nums" :style="similarityStyle">
        {{ t('tools.entityManager.duplicates.percentSimilar', { percent: similarityPercent }) }}
      </span>
    </div>

    <div
      class="flex flex-none flex-wrap items-center justify-between gap-2 border-b border-border px-5 py-2 text-xs text-muted-foreground"
      aria-live="polite"
    >
      <span>{{ t('tools.entityManager.duplicates.entityPageCount', { count: cluster.entities.length, total: entityTotal }) }}</span>
      <span>{{ t('tools.entityManager.duplicates.detailPage', { page, pages: totalPages }) }}</span>
      <span class="flex gap-2">
        <button
          type="button"
          class="rounded-md border border-border px-2 py-1 hover:bg-accent disabled:opacity-50 focus-visible:ring-2 focus-visible:ring-ring"
          :disabled="busy || page <= 1"
          :aria-label="t('tools.entityManager.duplicates.previousDetailPage')"
          @click="handlePreviousPage"
        >
          {{ t('tools.entityManager.browse.previousPage') }}
        </button>
        <button
          type="button"
          class="rounded-md border border-border px-2 py-1 hover:bg-accent disabled:opacity-50 focus-visible:ring-2 focus-visible:ring-ring"
          :disabled="busy || page >= totalPages"
          :aria-label="t('tools.entityManager.duplicates.nextDetailPage')"
          @click="handleNextPage"
        >
          {{ t('tools.entityManager.browse.nextPage') }}
        </button>
      </span>
    </div>
    <p v-if="detailError" class="px-5 py-2 text-sm text-destructive" role="alert">{{ detailError }}</p>
    <div class="min-h-0 flex-1 space-y-5 overflow-y-auto px-5 py-4" :aria-busy="detailLoading">
      <fieldset class="grid gap-3 sm:grid-cols-2" aria-labelledby="duplicate-compare-hint">
        <div v-for="entity in sortedEntities" :key="String(entity.id)" class="relative flex flex-col">
          <label
            class="flex flex-1 cursor-pointer flex-col rounded-xl border p-4 pe-11 transition-colors focus-within:ring-2 focus-within:ring-ring"
            :class="selectedTargetId === entity.id ? 'border-primary bg-primary/8' : 'border-border bg-card hover:bg-accent'"
          >
            <input
              type="radio"
              class="sr-only"
              name="duplicate-merge-target"
              :checked="selectedTargetId === entity.id"
              :disabled="busy || !canEdit"
              @change="handleSelectTarget(entity)"
            />
            <span
              class="text-[10.5px] font-bold uppercase tracking-wider"
              :class="selectedTargetId === entity.id ? 'text-primary' : 'text-muted-foreground'"
            >
              <template v-if="selectedTargetId === entity.id">{{ t('tools.entityManager.duplicates.keepThisOne') }}</template>
              <template v-else-if="sourceIds.includes(entity.id)">{{ t('tools.entityManager.duplicates.mergeAway') }}</template>
              <template v-else>{{ t('tools.entityManager.duplicates.notSelectedForMerge') }}</template>
            </span>

            <span class="mt-1 flex items-center gap-2">
              <span class="truncate text-[15px] font-semibold text-foreground">{{ entity.name }}</span>
              <Check v-if="selectedTargetId === entity.id" :size="15" class="shrink-0 text-primary" aria-hidden="true" />
            </span>
            <span class="mt-0.5 block text-xs text-muted-foreground">
              {{ t('tools.entityManager.bookCount', { count: entity.bookCount }) }}
              <template v-if="entity.sortName"> {{ t('tools.entityManager.sortPrefix', { sortName: entity.sortName }) }}</template>
            </span>

            <span v-if="entity.bookTitles.length > 0" class="mt-3 block">
              <span v-for="title in entity.bookTitles" :key="title" class="block truncate text-xs text-muted-foreground">
                {{ title }}
              </span>
            </span>
            <span v-else class="mt-3 block text-xs text-[var(--pill-warning)]">{{ t('tools.entityManager.duplicates.noBookTitles') }}</span>
          </label>

          <label v-if="canEdit && selectedTargetId !== entity.id" class="mt-2 flex items-center gap-2 text-xs text-muted-foreground">
            <input
              type="checkbox"
              class="accent-primary"
              :checked="sourceIds.includes(entity.id)"
              :disabled="busy"
              :aria-label="t('tools.entityManager.duplicates.includeInMerge', { name: entity.name })"
              @change="handleToggleSource(entity)"
            />
            <span class="min-w-0 truncate">{{ t('tools.entityManager.duplicates.includeInMerge', { name: entity.name }) }}</span>
          </label>
          <button
            v-if="canEdit && completeGroup"
            type="button"
            :disabled="busy"
            class="absolute end-3 top-3 grid size-6 place-items-center rounded text-muted-foreground transition-colors hover:bg-destructive/10 hover:text-destructive focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring"
            :aria-label="t('tools.entityManager.duplicates.dismissEntityTitle')"
            :title="t('tools.entityManager.duplicates.dismissEntityTitle')"
            @click="handleDismissEntity(entity.id)"
          >
            <UserMinus :size="13" aria-hidden="true" />
          </button>
        </div>
      </fieldset>

      <section v-if="cluster.pairDetails.length > 0 && (pairTotal > 1 || !completeGroup)">
        <h3 class="mb-2 text-[10.5px] font-bold uppercase tracking-wider text-muted-foreground">
          {{ t('tools.entityManager.duplicates.pairPageCount', { count: cluster.pairDetails.length, total: pairTotal }) }}
        </h3>
        <ul class="space-y-1">
          <li
            v-for="pair in cluster.pairDetails"
            :key="`${pair.idA}-${pair.idB}`"
            class="flex items-center gap-2 rounded-md bg-secondary px-2.5 py-1.5"
          >
            <span class="min-w-0 flex-1 truncate text-xs text-muted-foreground">
              {{ pair.nameA ?? entityName(pair.idA) }} &harr; {{ pair.nameB ?? entityName(pair.idB) }}
            </span>
            <span class="shrink-0 rounded px-1.5 py-0.5 text-[11px] font-semibold tabular-nums" :style="pairStyle(pair.similarity)">
              {{ pairPercent(pair.similarity) }}%
            </span>
            <button
              v-if="canEdit"
              type="button"
              :disabled="busy"
              class="grid size-6 shrink-0 place-items-center rounded text-muted-foreground transition-colors hover:bg-destructive/10 hover:text-destructive focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring"
              :aria-label="t('tools.entityManager.duplicates.dismissPairTitle')"
              :title="t('tools.entityManager.duplicates.dismissPairTitle')"
              @click="handleDismissPair(pair.idA, pair.idB)"
            >
              <X :size="12" aria-hidden="true" />
            </button>
          </li>
        </ul>
      </section>
    </div>

    <div v-if="canEdit" class="flex flex-none flex-wrap items-center gap-3 border-t border-border bg-secondary px-5 py-3">
      <span class="flex items-center gap-2">
        <ToggleSwitch v-model="writeFiles" aria-labelledby="duplicate-write-files" />
        <span id="duplicate-write-files" class="text-xs text-muted-foreground">{{ t('tools.entityManager.writeToFiles') }}</span>
      </span>
      <p class="text-xs text-muted-foreground">{{ t('tools.entityManager.duplicates.willBeMerged', { count: sourceIds.length }) }}</p>
      <div class="ms-auto flex items-center gap-2">
        <button
          type="button"
          class="inline-flex h-8 items-center gap-1.5 rounded-md border border-border px-3 text-xs font-semibold text-foreground transition-colors hover:bg-accent disabled:pointer-events-none disabled:opacity-50 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring"
          :disabled="busy || cluster.pairDetails.length === 0"
          :title="completeGroup ? t('tools.entityManager.duplicates.notAMatchTitle') : t('tools.entityManager.duplicates.dismissDisplayedPairs')"
          @click="handleDismissCluster"
        >
          <X :size="14" aria-hidden="true" />
          {{ completeGroup ? t('tools.entityManager.duplicates.notAMatch') : t('tools.entityManager.duplicates.dismissDisplayedPairs') }}
        </button>
        <button
          type="button"
          class="inline-flex h-8 items-center gap-1.5 rounded-md bg-primary px-3 text-xs font-semibold text-primary-foreground transition-colors hover:bg-primary/90 disabled:pointer-events-none disabled:opacity-50 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring"
          :disabled="busy || sourceIds.length === 0"
          @click="showPreview"
        >
          <GitMerge :size="14" aria-hidden="true" />
          {{ t('tools.entityManager.duplicates.previewSelectedMerge') }}
        </button>
      </div>
    </div>
    <ConfirmDialog
      :open="previewing"
      :title="t('tools.entityManager.duplicates.reviewSelectedMerge')"
      :description="t('tools.entityManager.duplicates.willBeMerged', { count: sourceIds.length })"
      :confirm-label="t('tools.entityManager.mergeIntoTarget', { count: sourceIds.length })"
      :busy="operationLoading"
      @confirm="handleMerge"
      @cancel="cancelPreview"
    >
      <div class="mt-3 max-h-64 overflow-y-auto text-sm">
        <p class="font-medium">{{ t('tools.entityManager.duplicates.keepThisOne') }}</p>
        <p>{{ targetEntity?.name }}</p>
        <p class="mt-3 font-medium">{{ t('tools.entityManager.duplicates.mergeAway') }}</p>
        <ul>
          <li v-for="entity in sourceEntities" :key="entity.id">{{ entity.name }}</li>
        </ul>
      </div>
    </ConfirmDialog>
  </div>
</template>
