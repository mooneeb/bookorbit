export interface BookmarkResponse {
  id: number;
  bookId: number;
  cfi: string | null;
  title: string;
  positionSeconds: number | null;
  fileId: number | null;
  pageNumber: number | null;
  createdAt: string;
  note: string | null;
  updatedAt: string;
  clientId: string;
  origin: string;
  chapterId: string | null;
}

export interface BookmarksPage {
  items: BookmarkResponse[];
  nextCursor: number | null;
}

export interface BookmarkPageQuery {
  fileId: number;
  limit?: number;
  beforeId?: number;
}

export interface EpubBookmarkPageQuery {
  limit?: number;
  beforeId?: number;
}

export type EpubBookmarkSort = "location" | "newest" | "oldest";

export interface EpubBookmarkNavigationQuery {
  fileId: number;
  limit?: number;
  query?: string;
  sort?: EpubBookmarkSort;
  cursor?: string;
  currentCfi?: string;
}

export interface EpubBookmarkNavigationItem extends BookmarkResponse {
  chapterTitle: string | null;
  contextPercentage: number | null;
  locationLabel: string;
}

export interface EpubBookmarkNavigationPage {
  bookId: number;
  fileId: number;
  fileRevision: string;
  query: string;
  sort: EpubBookmarkSort;
  items: EpubBookmarkNavigationItem[];
  nextCursor: string | null;
  currentBookmarkId: number | null;
  scannedCount: number;
  scanLimited: boolean;
}

export interface CreateFixedPageBookmarkPayload {
  fileId: number;
  pageNumber: number;
  title: string;
}

export interface CreateEpubBookmarkPayload {
  cfi: string;
  title: string;
}
