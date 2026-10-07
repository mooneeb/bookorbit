<script setup lang="ts">
import { computed, onUnmounted, ref, watch } from 'vue'
import { useI18n } from 'vue-i18n'
import { Bookmark } from '@lucide/vue'
import { Permission, type BookmarkResponse } from '@bookorbit/types'
import FormSheet from '@/components/FormSheet.vue'
import ConfirmDialog from '@/components/ui/ConfirmDialog.vue'
import { usePermissions } from '@/features/auth/composables/usePermissions'
import { useFixedPageBookmarks } from '../composables/useFixedPageBookmarks'

const props = defineProps<{ bookId: number; fileId: number; currentPage: number; pageCount: number }>()
const emit = defineEmits<{ navigate: [page: number]; 'update:open': [open: boolean] }>()
const { t } = useI18n()
const { hasPermission } = usePermissions()
const model = useFixedPageBookmarks(
  () => props.bookId,
  () => props.fileId,
)
const { items, loading, saving, loaded, error, outcome, nextCursor, hasPrevious, hasAcknowledgedBookmark } = model
const open = ref(false)
const title = ref('')
const removing = ref<BookmarkResponse | null>(null)
const canUse = computed(() => hasPermission(Permission.LibraryDownload))
const validTitle = computed(() => title.value.trim().length > 0 && title.value.length <= 500)
const validPage = computed(() => props.currentPage >= 1 && props.currentPage <= props.pageCount)
const errorText = computed(() => (error.value ? t('reader.fixedBookmarks.requestFailed') : null))

function setOpen(value: boolean) {
  if (saving.value) return
  open.value = value
  removing.value = null
  model.reset()
  if (value) {
    title.value = t('reader.fixedBookmarks.page', { page: props.currentPage })
    void model.first()
  }
  emit('update:open', value)
}
function show() {
  setOpen(true)
}
async function save() {
  const bookmark = await model.save(props.currentPage, title.value)
  if (bookmark && open.value) title.value = bookmark.title
}
function first() {
  void model.first()
}
function older() {
  void model.older()
}
function newer() {
  void model.newer()
}
function reload() {
  void model.load()
}
function select(bookmark: BookmarkResponse) {
  if (saving.value || loading.value || !bookmark.pageNumber || bookmark.pageNumber > props.pageCount) return
  emit('navigate', bookmark.pageNumber)
  setOpen(false)
}
function requestRemove(bookmark: BookmarkResponse) {
  removing.value = bookmark
}
function cancelRemove() {
  removing.value = null
}
async function confirmRemove() {
  if (!removing.value) return
  await model.remove(removing.value)
  removing.value = null
}
watch(
  () => [props.bookId, props.fileId],
  () => setOpen(false),
)
onUnmounted(model.reset)
</script>

<template>
  <button
    v-if="canUse"
    type="button"
    class="flex min-h-11 min-w-11 items-center justify-center rounded-md text-foreground hover:bg-muted focus-visible:ring-2 focus-visible:ring-ring"
    :aria-label="t('reader.fixedBookmarks.title')"
    :disabled="!validPage"
    @click="show"
  >
    <Bookmark :size="20" aria-hidden="true" />
  </button>
  <FormSheet
    :open="open"
    :title="t('reader.fixedBookmarks.title')"
    :description="t('reader.fixedBookmarks.description')"
    :busy="saving"
    :error="errorText"
    :submit-label="t('reader.fixedBookmarks.save')"
    :cancel-label="t('common.close')"
    :submit-disabled="loading || !loaded || !validTitle || !validPage"
    submit-test-id="save-fixed-bookmark"
    @update:open="setOpen"
    @submit="save"
  >
    <label class="block text-sm font-medium">
      {{ t('reader.fixedBookmarks.bookmarkPage', { page: props.currentPage }) }}
      <input
        v-model="title"
        :disabled="saving || loading"
        :aria-label="t('reader.fixedBookmarks.bookmarkTitle')"
        maxlength="500"
        class="mt-2 min-h-11 w-full rounded-md border border-input bg-background px-3 text-foreground focus-visible:ring-2 focus-visible:ring-ring"
      />
    </label>
    <p v-if="outcome" role="status">{{ t(`reader.fixedBookmarks.${outcome}`) }}</p>
    <button v-if="error" type="button" class="min-h-11 rounded-md border border-border px-3" :disabled="saving || loading" @click="reload">
      {{ t('common.retry') }}
    </button>
    <p v-if="loading" role="status">{{ t('common.loading') }}</p>
    <p v-if="hasAcknowledgedBookmark">{{ t('reader.fixedBookmarks.confirmedOnly') }}</p>
    <p v-if="loaded && !error && !items.length">{{ t('reader.fixedBookmarks.empty') }}</p>
    <ul class="space-y-3">
      <li v-for="bookmark in items" :key="bookmark.id" class="rounded-md border border-border p-2">
        <button
          type="button"
          class="min-h-11 w-full text-start text-foreground break-words"
          :disabled="saving || loading || !bookmark.pageNumber || bookmark.pageNumber > props.pageCount"
          @click="select(bookmark)"
        >
          <span class="block">{{ bookmark.title }}</span>
          <span class="block">{{ t('reader.fixedBookmarks.page', { page: bookmark.pageNumber }) }}</span>
        </button>
        <button
          type="button"
          class="min-h-11 rounded-md px-3 text-foreground hover:bg-muted"
          :aria-label="t('reader.fixedBookmarks.removeNamed', { title: bookmark.title })"
          :disabled="saving || loading"
          @click="requestRemove(bookmark)"
        >
          {{ t('reader.fixedBookmarks.remove') }}
        </button>
      </li>
    </ul>
    <div class="flex flex-wrap gap-2">
      <button type="button" class="min-h-11 rounded-md border border-border px-3" :disabled="saving || loading || !hasPrevious" @click="newer">
        {{ t('reader.fixedBookmarks.newer') }}
      </button>
      <button type="button" class="min-h-11 rounded-md border border-border px-3" :disabled="saving || loading || nextCursor === null" @click="older">
        {{ t('reader.fixedBookmarks.older') }}
      </button>
      <button type="button" class="min-h-11 rounded-md border border-border px-3" :disabled="saving || loading" @click="first">
        {{ t('reader.fixedBookmarks.first') }}
      </button>
    </div>
  </FormSheet>
  <ConfirmDialog
    :open="removing !== null"
    :title="t('reader.fixedBookmarks.removeConfirm')"
    :description="t('reader.fixedBookmarks.removeDescription')"
    :confirm-label="t('reader.fixedBookmarks.remove')"
    :busy="saving"
    @confirm="confirmRemove"
    @cancel="cancelRemove"
  />
</template>
