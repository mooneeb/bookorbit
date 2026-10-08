<script setup lang="ts">
import { computed, onMounted, onUnmounted, ref, watch } from 'vue'
import { useI18n } from 'vue-i18n'
import { AlertTriangle, ExternalLink, LoaderCircle } from '@lucide/vue'
import type { DocumentState } from '@embedpdf/core'
import { PdfErrorCode } from '@embedpdf/models'
import { useAnnotationCapability } from '@embedpdf/plugin-annotation/vue'
import { DocumentContent } from '@embedpdf/plugin-document-manager/vue'
import { useRotate } from '@embedpdf/plugin-rotate/vue'
import { ScrollStrategy, useScroll, useScrollCapability } from '@embedpdf/plugin-scroll/vue'
import { useSelectionCapability } from '@embedpdf/plugin-selection/vue'
import { SpreadMode, useSpread } from '@embedpdf/plugin-spread/vue'
import { ZoomMode, useZoom, type ZoomLevel } from '@embedpdf/plugin-zoom/vue'
import type { AnnotationItem, PdfReaderSettings } from '@bookorbit/types'
import { Permission } from '@bookorbit/types'
import { usePermissions } from '@/features/auth/composables/usePermissions'
import { toast } from 'vue-sonner'
import { useFullscreen } from '../../shared/composables/useFullscreen'
import PdfDocumentViewport from './PdfDocumentViewport.vue'
import PdfPasswordPrompt from './PdfPasswordPrompt.vue'
import PdfReaderSettingsPanel from './PdfReaderSettingsPanel.vue'
import PdfReaderSidebar from './PdfReaderSidebar.vue'
import PdfReaderToolbar from './PdfReaderToolbar.vue'
import { fromRotation, safeExternalPdfUrl } from '../pdf-viewer-utils'
import { usePdfFullscreenChrome } from '../composables/usePdfFullscreenChrome'
import { usePdfHighlights } from '../composables/usePdfHighlights'
import { usePdfInteractionMode } from '../composables/usePdfInteractionMode'
import { usePdfPagination } from '../composables/usePdfPagination'
import { usePdfResponsiveSpread } from '../composables/usePdfResponsiveSpread'
import { usePdfSidebarLayout, type PdfSidebarTab } from '../composables/usePdfSidebarLayout'
import NoteDialog from '../../shared/components/NoteDialog.vue'
import PdfSelectionPopup from './PdfSelectionPopup.vue'
import ReaderBookmarksButton from '../../shared/components/ReaderBookmarksButton.vue'
import type { useSourcePdfInk } from '../composables/useSourcePdfInk'

const props = defineProps<{
  documentId: string
  bookId: number
  fileId: number
  initialPage: number
  settings: PdfReaderSettings
  peekMode?: boolean
  sourceInk?: ReturnType<typeof useSourcePdfInk>
}>()

const { t } = useI18n()
const { hasPermission } = usePermissions()
const canManageAnnotations = computed(() => hasPermission(Permission.AnnotationManageOwn))

const emit = defineEmits<{
  back: []
  pageChange: [pageNumber: number, totalPages: number]
  retry: []
  settingsChange: [patch: Partial<PdfReaderSettings>]
  startReading: []
}>()

const { state: scrollState, provides: scroll } = useScroll(() => props.documentId)
const { provides: scrollCapability } = useScrollCapability()
const { state: zoomState, provides: zoom } = useZoom(() => props.documentId)
const { provides: spread } = useSpread(() => props.documentId)
const { rotation, provides: rotate } = useRotate(() => props.documentId)
const { isPanning, togglePan, activateTextSelection } = usePdfInteractionMode(() => props.documentId)
const { provides: selectionCapability } = useSelectionCapability()
const { provides: annotationCapability } = useAnnotationCapability()
const { isFullscreen, isFullscreenSupported, toggleFullscreen } = useFullscreen()

const sidebar = usePdfSidebarLayout()
const settingsOpen = ref(false)
const bookmarksOpen = ref(false)
const pendingExternalUrl = ref<URL | null>(null)
const restoredInitialPage = ref(false)
const viewerSurface = ref<HTMLElement | null>(null)
const selectionPopup = ref<{ getElement: () => HTMLElement | null } | null>(null)
const currentScrollMode = ref<PdfReaderSettings['scrollMode']>(props.settings.scrollMode)
const currentSpreadPreference = ref<PdfReaderSettings['spread']>(props.settings.spread)
let previewingZoom = false
const zoomPercent = computed(() => Math.round(zoomState.value.currentZoomLevel * 100))
const currentZoomMode = computed<PdfReaderSettings['zoomMode']>(() => {
  if (zoomState.value.zoomLevel === ZoomMode.FitPage) return 'fit-page'
  if (zoomState.value.zoomLevel === ZoomMode.FitWidth) return 'fit-width'
  if (zoomState.value.zoomLevel === ZoomMode.Automatic) return 'automatic'
  return 'custom'
})
const currentRotation = computed(() => fromRotation(rotation.value))
const externalHost = computed(() => pendingExternalUrl.value?.hostname ?? '')
const hasOpenUi = computed(() => sidebar.open.value || settingsOpen.value || bookmarksOpen.value || pendingExternalUrl.value !== null)
const {
  pinned: headerPinned,
  visible: headerVisible,
  reveal: revealHeader,
  togglePinned: toggleHeaderPinned,
} = usePdfFullscreenChrome(isFullscreen, hasOpenUi)
const {
  pageRange,
  getPageRange,
  goToPage: handleGoToPage,
  previousPage: handlePreviousPage,
  nextPage: handleNextPage,
  handleWheel: handleViewportWheel,
  handleTouchStart,
  handleTouchEnd,
  handleTouchCancel,
} = usePdfPagination({
  mode: currentScrollMode,
  scrollState,
  scroll,
  touchPageTurningEnabled: isPanning,
  onActivity: revealHeader,
})
const { apply: applyResponsiveSpread } = usePdfResponsiveSpread(viewerSurface, currentSpreadPreference, spread)
const highlights = usePdfHighlights({
  bookId: props.bookId,
  fileId: props.fileId,
  documentId: () => props.documentId,
  getSurface: () => viewerSurface.value,
  getPopup: () => selectionPopup.value?.getElement() ?? null,
})

watch(pageRange, (range) => props.sourceInk?.setVisiblePages(range.start - 1, range.end - 1), { immediate: true })

function handleBack() {
  emit('back')
}

function handleZoomOut() {
  zoom.value?.zoomOut()
}

function handleZoomIn() {
  zoom.value?.zoomIn()
}

function handleToggleSidebar() {
  sidebar.setOpen(!sidebar.open.value)
}

function handleSidebarClose() {
  sidebar.close()
}

function handleSidebarTab(tab: PdfSidebarTab) {
  sidebar.selectTab(tab)
}

function handleSidebarWidth(width: number) {
  sidebar.setWidth(width)
}

function handleTogglePan() {
  togglePan()
}

function handleSelectTool() {
  activateTextSelection()
}

function handleSettingsOpen(open: boolean) {
  settingsOpen.value = open
}

function handleBookmarksOpen(open: boolean) {
  bookmarksOpen.value = open
}

function handleStartReading() {
  emit('startReading')
}

function handleHighlightAction(color: string, style: string) {
  void highlights.applyHighlight(color, style)
}

function handleHighlightNote() {
  highlights.openNoteDialog()
}

function handleHighlightNoteText(value: string) {
  highlights.noteText.value = value
}

async function handleHighlightSaveNote(note: string) {
  if (!(await highlights.saveNote(note))) toast.error(t('annotations.sync.status.failed'))
}

function handleHighlightCancelNote() {
  highlights.cancelNoteDialog()
}

function handleHighlightDismiss() {
  highlights.dismissPopup()
}

function handleNavigateHighlight(annotation: AnnotationItem) {
  highlights.navigateTo(annotation)
  if (sidebar.layout.value === 'sheet') sidebar.close()
}

function handleDeleteHighlight(id: number) {
  const ink = props.sourceInk?.items.value.find((item) => item.id === id)
  if (ink) {
    props.sourceInk?.select(ink)
    props.sourceInk?.removeSelected()
    return
  }
  void highlights.deleteAnnotation(id)
}

function handleSelectInk(item: AnnotationItem) {
  highlights.dismissPopup()
  props.sourceInk?.select(item)
}
function handleContextInk(item: AnnotationItem, event: MouseEvent) {
  highlights.dismissPopup()
  props.sourceInk?.select(item, event)
}
function handleDeleteInk() {
  props.sourceInk?.removeSelected()
}
function handleUndoInk() {
  void props.sourceInk?.undo()
}
function handleRetryInk() {
  props.sourceInk?.retry()
}

function handleRetryHighlights() {
  void highlights.retryLoad()
}

function handleLoadMoreHighlights() {
  void highlights.loadMore()
}

function handleSelectionPopupResize() {
  highlights.repositionPopup()
}

function handleScrollMode(mode: PdfReaderSettings['scrollMode']) {
  currentScrollMode.value = mode
  scroll.value?.setScrollStrategy(mode === 'horizontal' ? ScrollStrategy.Horizontal : ScrollStrategy.Vertical)
  emit('settingsChange', { scrollMode: mode })
  handleGoToPage(pageRange.value.start)
}

function handleSpread(mode: PdfReaderSettings['spread']) {
  currentSpreadPreference.value = mode
  emit('settingsChange', { spread: mode })
  if (mode === 'auto') applyResponsiveSpread()
  else spread.value?.setSpreadMode(mode === 'odd' ? SpreadMode.Odd : mode === 'even' ? SpreadMode.Even : SpreadMode.None)
}

function handleZoom(mode: PdfReaderSettings['zoomMode'], scale?: number) {
  let value: ZoomLevel = ZoomMode.FitPage
  if (mode === 'fit-width') value = ZoomMode.FitWidth
  if (mode === 'automatic') value = ZoomMode.Automatic
  if (mode === 'custom') value = scale ?? zoomState.value.currentZoomLevel
  zoom.value?.requestZoom(value)
}

function handleZoomPreview(scale: number) {
  previewingZoom = true
  try {
    zoom.value?.requestZoom(scale)
  } finally {
    previewingZoom = false
  }
}

function handleRotateBackward() {
  rotate.value?.rotateBackward()
}

function handleRotateForward() {
  rotate.value?.rotateForward()
}

function handleCancelExternalLink() {
  pendingExternalUrl.value = null
}

function handleOpenExternalLink() {
  const url = pendingExternalUrl.value
  pendingExternalUrl.value = null
  if (url) window.open(url.href, '_blank', 'noopener,noreferrer')
}

function handleRetryDocument() {
  emit('retry')
}

function hasDocumentPages(documentState: DocumentState) {
  return (documentState.document?.pageCount ?? 0) > 0
}

function handleReaderActivity() {
  revealHeader()
}

function handleKeydown(event: KeyboardEvent) {
  revealHeader()
  if (bookmarksOpen.value) return
  const target = event.target as HTMLElement | null
  const editing = target?.matches('input, textarea, select, button, a, [role="button"], [role="menuitem"], [contenteditable="true"]') === true

  if (!editing && (event.metaKey || event.ctrlKey) && event.key.toLowerCase() === 'z' && props.sourceInk?.undoItem.value) {
    event.preventDefault()
    handleUndoInk()
    return
  }
  if (!editing && (event.key === 'Delete' || event.key === 'Backspace') && props.sourceInk?.selected.value) {
    event.preventDefault()
    handleDeleteInk()
    return
  }

  if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === 'f') {
    event.preventDefault()
    sidebar.selectTab('search')
    return
  }
  if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === 'c' && !editing) {
    selectionCapability.value?.forDocument(props.documentId).copyToClipboard()
    return
  }
  if (editing) return

  if (event.key === 'Escape') {
    if (props.sourceInk?.selected.value || props.sourceInk?.menu.value) props.sourceInk.dismiss()
    else if (pendingExternalUrl.value) handleCancelExternalLink()
    else if (sidebar.open.value) handleSidebarClose()
    return
  }
  if (event.key === 'ArrowLeft' || event.key === 'PageUp') {
    event.preventDefault()
    handlePreviousPage()
  } else if (event.key === 'ArrowRight' || event.key === 'PageDown') {
    event.preventDefault()
    handleNextPage()
  } else if (event.key === 'Home') {
    event.preventDefault()
    handleGoToPage(1)
  } else if (event.key === 'End') {
    event.preventDefault()
    handleGoToPage(scrollState.value.totalPages)
  } else if (event.key === '+' || event.key === '=') {
    event.preventDefault()
    handleZoomIn()
  } else if (event.key === '-') {
    event.preventDefault()
    handleZoomOut()
  } else if (event.key === '0') {
    event.preventDefault()
    handleZoom(currentZoomMode.value === 'custom' ? 'fit-page' : currentZoomMode.value)
  }
}

watch(
  () => props.settings.scrollMode,
  (mode) => {
    currentScrollMode.value = mode
  },
)

watch(
  () => props.settings.spread,
  (mode) => {
    currentSpreadPreference.value = mode
    if (mode === 'auto') applyResponsiveSpread()
  },
)

watch(
  scrollCapability,
  (capability, _previous, onCleanup) => {
    if (!capability) return
    const unsubscribeLayout = capability.onLayoutReady((event) => {
      if (event.documentId !== props.documentId || event.totalPages <= 0) return
      if (restoredInitialPage.value) return
      highlights.renderAll()
      const page = Math.min(Math.max(props.initialPage, 1), event.totalPages)
      scroll.value?.scrollToPage({ pageNumber: page, behavior: 'instant' })
      restoredInitialPage.value = true
    })
    const unsubscribePage = capability.onPageChange((event) => {
      if (event.documentId !== props.documentId || !restoredInitialPage.value) return
      const range = getPageRange(event.pageNumber, event.totalPages)
      emit('pageChange', range.end, event.totalPages)
    })
    onCleanup(() => {
      unsubscribeLayout()
      unsubscribePage()
    })
  },
  { immediate: true },
)

watch(
  zoom,
  (scope, _previous, onCleanup) => {
    if (!scope) return
    const unsubscribe = scope.onZoomChange((event) => {
      if (previewingZoom) return
      if (event.level === ZoomMode.FitPage) emit('settingsChange', { zoomMode: 'fit-page' })
      else if (event.level === ZoomMode.FitWidth) emit('settingsChange', { zoomMode: 'fit-width' })
      else if (event.level === ZoomMode.Automatic) emit('settingsChange', { zoomMode: 'automatic' })
      else emit('settingsChange', { zoomMode: 'custom', customScale: event.newZoom })
    })
    onCleanup(unsubscribe)
  },
  { immediate: true },
)

watch(
  spread,
  (scope, _previous, onCleanup) => {
    if (!scope) return
    const unsubscribe = scope.onSpreadChange((mode) => {
      if (currentSpreadPreference.value === 'auto') return
      emit('settingsChange', { spread: mode === SpreadMode.Odd ? 'odd' : mode === SpreadMode.Even ? 'even' : 'none' })
    })
    onCleanup(unsubscribe)
  },
  { immediate: true },
)

watch(
  rotate,
  (scope, _previous, onCleanup) => {
    if (!scope) return
    const unsubscribe = scope.onRotateChange((value) => emit('settingsChange', { rotation: fromRotation(value) }))
    onCleanup(unsubscribe)
  },
  { immediate: true },
)

watch(
  annotationCapability,
  (capability, _previous, onCleanup) => {
    if (!capability) return
    const unsubscribe = capability.forDocument(props.documentId).onNavigate((event) => {
      if (event.result.outcome !== 'uri') return
      pendingExternalUrl.value = safeExternalPdfUrl(event.result.uri)
    })
    onCleanup(unsubscribe)
  },
  { immediate: true },
)

onMounted(() => {
  window.addEventListener('keydown', handleKeydown)
})
onUnmounted(() => {
  window.removeEventListener('keydown', handleKeydown)
})
</script>

<template>
  <div class="flex h-full min-h-0 flex-col overflow-hidden bg-background" @mousemove="handleReaderActivity" @pointerdown="handleReaderActivity">
    <PdfReaderToolbar
      v-show="headerVisible"
      :current-page-start="pageRange.start"
      :current-page-end="pageRange.end"
      :total-pages="scrollState.totalPages"
      :zoom-percent="zoomPercent"
      :sidebar-open="sidebar.open.value"
      :show-sidebar-toggle="sidebar.layout.value === 'sheet'"
      :settings-open="settingsOpen"
      :pan-active="isPanning"
      :fullscreen="isFullscreen"
      :fullscreen-supported="isFullscreenSupported"
      :header-pinned="headerPinned"
      :peek-mode="props.peekMode"
      @back="handleBack"
      @previous-page="handlePreviousPage"
      @next-page="handleNextPage"
      @go-to-page="handleGoToPage"
      @zoom-out="handleZoomOut"
      @zoom-in="handleZoomIn"
      @toggle-sidebar="handleToggleSidebar"
      @toggle-pan="handleTogglePan"
      @select-tool="handleSelectTool"
      @toggle-fullscreen="toggleFullscreen"
      @toggle-header-pin="toggleHeaderPinned"
      @update:settings-open="handleSettingsOpen"
      @start-reading="handleStartReading"
    >
      <template #bookmarks>
        <ReaderBookmarksButton
          v-if="!props.peekMode"
          :book-id="props.bookId"
          :file-id="props.fileId"
          :current-page="scrollState.currentPage"
          :page-count="scrollState.totalPages"
          @navigate="handleGoToPage"
          @update:open="handleBookmarksOpen"
        />
      </template>
      <template #settings>
        <PdfReaderSettingsPanel
          :scroll-mode="currentScrollMode"
          :spread="currentSpreadPreference"
          :rotation="currentRotation"
          :zoom-mode="currentZoomMode"
          :custom-scale="zoomState.currentZoomLevel"
          @preview-zoom="handleZoomPreview"
          @set-scroll-mode="handleScrollMode"
          @set-spread="handleSpread"
          @set-zoom="handleZoom"
          @rotate-backward="handleRotateBackward"
          @rotate-forward="handleRotateForward"
        />
      </template>
    </PdfReaderToolbar>

    <div class="relative flex min-h-0 flex-1 overflow-hidden">
      <PdfReaderSidebar
        :document-id="props.documentId"
        :active-tab="sidebar.activeTab.value"
        :open="sidebar.open.value"
        :layout="sidebar.layout.value"
        :width="sidebar.width.value"
        :annotations="highlights.annotations.value"
        :load-error="highlights.loadError.value"
        :loading="highlights.loading.value"
        :loading-more="highlights.loadingMore.value"
        :has-more="highlights.hasMore.value"
        @close="handleSidebarClose"
        @update:active-tab="handleSidebarTab"
        @update:width="handleSidebarWidth"
        @navigate-highlight="handleNavigateHighlight"
        @delete-highlight="handleDeleteHighlight"
        @retry-highlights="handleRetryHighlights"
        @load-more-highlights="handleLoadMoreHighlights"
      />

      <div
        ref="viewerSurface"
        class="relative min-w-0 flex-1 overflow-hidden"
        @wheel="handleViewportWheel"
        @touchstart="handleTouchStart"
        @touchend="handleTouchEnd"
        @touchcancel="handleTouchCancel"
      >
        <DocumentContent :document-id="props.documentId">
          <template #default="{ documentState, isLoading, isError, isLoaded }">
            <div v-if="isLoading" class="absolute inset-0 flex items-center justify-center bg-background">
              <div class="flex flex-col items-center gap-3 text-muted-foreground" role="status" aria-live="polite">
                <LoaderCircle :size="28" class="animate-spin text-primary" />
                <span class="text-sm">{{ t('reader.pdf.loading') }}</span>
              </div>
            </div>
            <PdfPasswordPrompt
              v-else-if="isError && documentState.errorCode === PdfErrorCode.Password"
              :document-state="documentState"
              @back="handleBack"
            />
            <div v-else-if="isError" class="absolute inset-0 flex items-center justify-center p-6">
              <div class="max-w-sm text-center">
                <AlertTriangle :size="30" class="mx-auto mb-3 text-destructive" />
                <p class="mb-2 text-sm font-medium text-foreground">{{ t('reader.pdf.openError') }}</p>
                <p class="text-xs text-muted-foreground">{{ documentState.error || t('reader.pdf.loadFallback') }}</p>
                <div class="mt-4 flex justify-center gap-2">
                  <button
                    class="rounded-md border border-border px-3 py-2 text-xs font-semibold text-muted-foreground hover:text-foreground"
                    @click="handleBack"
                  >
                    {{ t('reader.header.goBack') }}
                  </button>
                  <button class="rounded-md bg-primary px-3 py-2 text-xs font-semibold text-primary-foreground" @click="handleRetryDocument">
                    {{ t('reader.retry') }}
                  </button>
                </div>
              </div>
            </div>
            <div v-else-if="isLoaded && !hasDocumentPages(documentState)" class="absolute inset-0 flex items-center justify-center p-6">
              <div class="max-w-sm text-center">
                <AlertTriangle :size="30" class="mx-auto mb-3 text-destructive" />
                <p class="mb-2 text-sm font-medium text-foreground">{{ t('reader.pdf.noPages') }}</p>
                <p class="text-xs text-muted-foreground">{{ t('reader.pdf.noPagesHint') }}</p>
                <div class="mt-4 flex justify-center gap-2">
                  <button
                    class="rounded-md border border-border px-3 py-2 text-xs font-semibold text-muted-foreground hover:text-foreground"
                    @click="handleBack"
                  >
                    {{ t('reader.header.goBack') }}
                  </button>
                  <button class="rounded-md bg-primary px-3 py-2 text-xs font-semibold text-primary-foreground" @click="handleRetryDocument">
                    {{ t('reader.retry') }}
                  </button>
                </div>
              </div>
            </div>
            <PdfDocumentViewport
              v-else-if="isLoaded"
              :document-id="props.documentId"
              :source-ink="props.sourceInk?.items.value"
              :selected-ink-id="props.sourceInk?.selectedId.value"
              @select-ink="handleSelectInk"
              @context-ink="handleContextInk"
            />
          </template>
        </DocumentContent>
        <PdfSelectionPopup
          ref="selectionPopup"
          :visible="highlights.popupVisible.value"
          :position="highlights.popupPosition.value"
          :show-below="highlights.popupShowBelow.value"
          :selected-text="highlights.selectedText.value"
          :overlapping-annotation-id="highlights.overlappingAnnotationId.value"
          :disabled="highlights.isSaving.value"
          :can-annotate="canManageAnnotations"
          @highlight="handleHighlightAction"
          @note="handleHighlightNote"
          @delete-annotation="handleDeleteHighlight"
          @dismiss="handleHighlightDismiss"
          @resize="handleSelectionPopupResize"
        />
      </div>
    </div>

    <div
      v-if="props.sourceInk?.selected.value || props.sourceInk?.undoItem.value || props.sourceInk?.failed.value"
      class="flex shrink-0 items-center justify-end gap-2 border-t border-border bg-card px-3 py-2"
      role="status"
      aria-live="polite"
    >
      <span v-if="props.sourceInk?.busy.value" class="text-xs text-muted-foreground">{{ t('annotations.listItem.saving') }}</span>
      <button
        v-if="props.sourceInk?.selected.value && props.sourceInk?.canEdit.value"
        class="rounded-md border border-border px-3 py-2 text-xs text-destructive disabled:opacity-50"
        :disabled="props.sourceInk?.busy.value"
        @click="handleDeleteInk"
      >
        {{ t('common.delete') }}
      </button>
      <button
        v-if="props.sourceInk?.undoItem.value && props.sourceInk?.canEdit.value"
        class="rounded-md border border-border px-3 py-2 text-xs"
        @click="handleUndoInk"
      >
        {{ t('common.undo') }}
      </button>
      <template v-if="props.sourceInk?.failed.value">
        <span class="text-xs text-destructive">{{ t('annotations.sync.status.failed') }}</span>
        <button class="rounded-md border border-border px-3 py-2 text-xs" @click="handleRetryInk">{{ t('reader.retry') }}</button>
      </template>
    </div>
    <div
      v-if="props.sourceInk?.menu.value && props.sourceInk?.canEdit.value"
      class="fixed z-[80] rounded-md border border-border bg-card p-1 shadow-lg"
      :style="{ left: `${props.sourceInk.menu.value.x}px`, top: `${props.sourceInk.menu.value.y}px` }"
      role="menu"
    >
      <button class="block w-full rounded px-3 py-2 text-start text-sm text-destructive hover:bg-muted" role="menuitem" @click="handleDeleteInk">
        {{ t('common.delete') }}
      </button>
    </div>

    <div v-if="pendingExternalUrl" class="fixed inset-0 z-[70] flex items-center justify-center bg-scrim p-4">
      <div class="w-full max-w-md rounded-xl border border-border bg-card p-5 text-card-foreground shadow-2xl">
        <div class="mb-4 flex items-start gap-3">
          <div class="flex h-9 w-9 shrink-0 items-center justify-center rounded-full bg-primary/10 text-primary"><ExternalLink :size="18" /></div>
          <div class="min-w-0">
            <h2 class="font-serif text-base font-semibold">{{ t('reader.pdf.externalLinkTitle') }}</h2>
            <p class="mt-1 text-xs text-muted-foreground">{{ t('reader.pdf.externalLinkDescription', { host: externalHost }) }}</p>
            <p class="mt-2 truncate rounded-md bg-muted px-2 py-1.5 text-[11px] text-muted-foreground">{{ pendingExternalUrl.href }}</p>
          </div>
        </div>
        <div class="flex justify-end gap-2">
          <button
            class="rounded-md border border-border px-3 py-2 text-xs font-semibold text-muted-foreground hover:text-foreground"
            @click="handleCancelExternalLink"
          >
            {{ t('common.cancel') }}
          </button>
          <button class="rounded-md bg-primary px-3 py-2 text-xs font-semibold text-primary-foreground" @click="handleOpenExternalLink">
            {{ t('reader.pdf.openLink') }}
          </button>
        </div>
      </div>
    </div>

    <NoteDialog
      v-if="highlights.showNoteDialog.value"
      :selectedText="highlights.selectedText.value"
      :modelValue="highlights.noteText.value"
      :saving="highlights.isSaving.value"
      :drawing="highlights.annotations.value.find((annotation) => annotation.id === highlights.overlappingAnnotationId.value)?.drawing"
      :readonly="!canManageAnnotations"
      @update:modelValue="handleHighlightNoteText"
      @save="handleHighlightSaveNote"
      @cancel="handleHighlightCancelNote"
    />
  </div>
</template>
