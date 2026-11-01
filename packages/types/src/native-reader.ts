/** Transfer lease for an immutable original and its unmodified archive members. */
export interface NativeEpubSession {
  version: 1;
  id: string;
  bookId: number;
  fileId: number;
  sourceSha256: string;
  sourceBytes: number;
  sourceFileId: string;
  sourceRevision: string;
  instanceId: string;
  accountId: number;
  expiresAt: string;
  members: { path: string; bytes: number; sha256: string }[];
}

export interface NativeReaderCapabilities {
  version: 1;
  instanceId: string;
  accountId: number;
  packageVersion: 1;
  limits: { sourceBytes: number; expandedBytes: number; entries: number; manifestBytes: number; textBytes: number; memberBytes: number };
}
