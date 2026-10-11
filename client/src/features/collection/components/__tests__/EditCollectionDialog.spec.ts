import { flushPromises, mount } from '@vue/test-utils'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import type { Collection } from '@bookorbit/types'
import type { Router } from 'vue-router'
import type { useCollections } from '../../composables/useCollections'
import EditCollectionDialog from '../EditCollectionDialog.vue'

const mockState = vi.hoisted(() => ({
  canSyncToKobo: true,
  updateCollection: vi.fn<ReturnType<typeof useCollections>['updateCollection']>(),
}))
vi.mock('@/features/auth/composables/usePermissions', () => ({
  usePermissions: () => ({ hasPermission: () => mockState.canSyncToKobo }),
}))
vi.mock('@/features/collection/composables/useCollections', () => ({
  useCollections: () => ({
    updateCollection: mockState.updateCollection,
    deleteCollection: vi.fn<ReturnType<typeof useCollections>['deleteCollection']>(),
  }),
}))
vi.mock('vue-router', () => ({ useRouter: () => ({ replace: vi.fn<Router['replace']>() }) }))

function makeCollection(overrides: Partial<Collection> = {}): Collection {
  return {
    id: 4,
    userId: 7,
    mediaType: 'books',
    name: 'Favorites',
    icon: 'FolderOpen',
    description: null,
    isPublic: false,
    isOwner: true,
    syncToKobo: false,
    displayOrder: 0,
    bookCount: 0,
    podcastCount: 0,
    createdAt: '2026-01-01T00:00:00.000Z',
    updatedAt: '2026-01-01T00:00:00.000Z',
    ...overrides,
  }
}

async function openDialog() {
  const wrapper = mount(EditCollectionDialog, {
    props: { open: false, collection: makeCollection({ syncToKobo: true }) },
    global: { stubs: { Teleport: true, IconPicker: true } },
  })
  await wrapper.setProps({ open: true })
  return wrapper
}

describe('EditCollectionDialog Kobo permission', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    mockState.canSyncToKobo = true
    mockState.updateCollection.mockResolvedValue(makeCollection())
  })

  it('shows the Kobo toggle to a permitted user', async () => {
    const wrapper = await openDialog()
    expect(wrapper.find('[aria-label="Sync to Kobo"]').exists()).toBe(true)
  })

  it('hides Kobo control and omits its flag from ordinary save without permission', async () => {
    mockState.canSyncToKobo = false
    const wrapper = await openDialog()
    expect(wrapper.find('[aria-label="Sync to Kobo"]').exists()).toBe(false)
    await wrapper.find('form').trigger('submit')
    await flushPromises()
    expect(mockState.updateCollection).toHaveBeenCalledWith(4, 'Favorites', 'FolderOpen', undefined, false)
  })
})
