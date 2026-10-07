export interface BookmarkResponse {
  id: number;
  bookId: number;
  cfi: string | null;
  title: string;
  positionSeconds: number | null;
  fileId: number | null;
  pageNumber: number | null;
  createdAt: string;
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

export interface CreateFixedPageBookmarkPayload {
  fileId: number;
  pageNumber: number;
  title: string;
}

export interface CreateEpubBookmarkPayload {
  cfi: string;
  title: string;
}
