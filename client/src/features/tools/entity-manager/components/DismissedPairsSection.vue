<script setup lang="ts">
import { RotateCcw } from '@lucide/vue'
import { useI18n } from 'vue-i18n'
import type { DismissedPairInfo } from '@bookorbit/types'
import { Permission } from '@bookorbit/types'
import { usePermissions } from '@/features/auth/composables/usePermissions'

const { t } = useI18n()

const props = defineProps<{
  pairs: DismissedPairInfo[]
  loading: boolean
  operationLoading: boolean
  page: number
  total: number
  totalPages: number
  error: string | null
}>()
const { hasPermission } = usePermissions()

const emit = defineEmits<{
  undismiss: [idA: number | string, idB: number | string]
  'update:page': [value: number]
}>()

function handleUndismiss(pair: DismissedPairInfo): void {
  emit('undismiss', pair.idA, pair.idB)
}

function handlePreviousPage(): void {
  emit('update:page', props.page - 1)
}

function handleNextPage(): void {
  emit('update:page', props.page + 1)
}
</script>

<template>
  <div class="space-y-2">
    <p v-if="error" role="alert" class="text-sm text-destructive">{{ error }}</p>
    <div class="flex flex-wrap items-center justify-between gap-2 py-2 text-xs text-muted-foreground" aria-live="polite">
      <span>{{ t('tools.entityManager.dismissed.pageSummary', { page, pages: totalPages, total }) }}</span>
      <span>{{ t('tools.entityManager.dismissed.pairCount', { count: total }) }}</span>
      <span class="flex gap-2">
        <button
          type="button"
          class="rounded-md border border-border px-2 py-1 hover:bg-accent disabled:opacity-50 focus-visible:ring-2 focus-visible:ring-ring"
          :disabled="loading || operationLoading || page <= 1"
          :aria-label="t('tools.entityManager.dismissed.previousPage')"
          @click="handlePreviousPage"
        >
          {{ t('tools.entityManager.browse.previousPage') }}
        </button>
        <button
          type="button"
          class="rounded-md border border-border px-2 py-1 hover:bg-accent disabled:opacity-50 focus-visible:ring-2 focus-visible:ring-ring"
          :disabled="loading || operationLoading || page >= totalPages"
          :aria-label="t('tools.entityManager.dismissed.nextPage')"
          @click="handleNextPage"
        >
          {{ t('tools.entityManager.browse.nextPage') }}
        </button>
      </span>
    </div>
    <div v-if="loading" class="text-center py-4 text-sm text-muted-foreground">{{ t('tools.entityManager.dismissed.loading') }}</div>
    <div v-else-if="pairs.length === 0" class="text-center py-4 text-sm text-muted-foreground">{{ t('tools.entityManager.dismissed.empty') }}</div>
    <div v-else class="divide-y divide-border border border-border rounded-lg overflow-hidden">
      <div
        v-for="pair in pairs"
        :key="`${pair.idA}-${pair.idB}`"
        data-testid="dismissed-pair"
        class="flex items-center justify-between px-4 py-2.5 hover:bg-muted/30 transition-colors"
      >
        <div class="flex-1 min-w-0 break-words">
          <span class="text-sm">{{ pair.nameA }}</span>
          <span class="text-muted-foreground mx-2">&harr;</span>
          <span class="text-sm">{{ pair.nameB }}</span>
          <span v-if="pair.reason" class="text-xs text-muted-foreground ml-2">({{ pair.reason }})</span>
        </div>
        <button
          v-if="hasPermission(Permission.LibraryEditMetadata)"
          type="button"
          :disabled="operationLoading"
          class="inline-flex items-center gap-1 h-7 px-2 text-xs rounded hover:bg-muted text-muted-foreground hover:text-foreground transition-colors shrink-0"
          :title="t('tools.entityManager.dismissed.restoreTitle')"
          @click="handleUndismiss(pair)"
        >
          <RotateCcw class="h-3.5 w-3.5" />
          {{ t('tools.entityManager.dismissed.restore') }}
        </button>
      </div>
    </div>
  </div>
</template>
