/** An expiring online lease. It is never an offline-ready or synchronization receipt. */
export interface NativeEpubSession {
  version: 1;
  id: string;
  bookId: number;
  fileId: number;
  sourceSha256: string;
  sourceBytes: number;
  expiresAt: string;
  members: { path: string; bytes: number; sha256: string }[];
}
