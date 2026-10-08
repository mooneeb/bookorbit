import type { FileMetadata } from '../composables/useFileMetadata'
import type { MetadataPatch } from '../composables/useMetadataDiff'

export type MetadataFormPatch = Omit<MetadataPatch, 'comicMetadata'> & Pick<FileMetadata, 'comicMetadata'>

const FILE_METADATA_PATCH_FIELDS = [
  'title',
  'subtitle',
  'description',
  'publisher',
  'publishedDate',
  'publishedYear',
  'language',
  'pageCount',
  'seriesName',
  'seriesIndex',
  'isbn10',
  'isbn13',
  'googleBooksId',
  'goodreadsId',
  'amazonId',
  'hardcoverId',
  'hardcoverEditionId',
  'openLibraryId',
  'itunesId',
  'audibleId',
  'librofmId',
  'koboId',
  'comicvineId',
  'ranobedbId',
  'lubimyczytacId',
  'aladinId',
  'authors',
  'genres',
  'narrators',
  'durationSeconds',
] as const satisfies readonly (keyof FileMetadata & keyof MetadataPatch)[]

export function buildFileMetadataPatch(meta: FileMetadata): MetadataFormPatch {
  const patch: MetadataFormPatch = {}

  for (const field of FILE_METADATA_PATCH_FIELDS) {
    if (meta[field] !== undefined) {
      patch[field] = meta[field] as never
    }
  }

  if (meta.comicMetadata !== undefined) {
    patch.comicMetadata = meta.comicMetadata
  }
  if (meta.customMetadata !== undefined) {
    patch.customMetadata = meta.customMetadata
  }

  return patch
}
