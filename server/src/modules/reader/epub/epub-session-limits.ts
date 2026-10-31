export const EPUB_SESSION_LIMITS = Symbol('EPUB_SESSION_LIMITS');

export const DEFAULT_EPUB_SESSION_LIMITS = {
  sourceBytes: 512 * 1024 * 1024,
  expandedBytes: 2048 * 1024 * 1024,
  globalBytes: 10240 * 1024 * 1024,
  accountBytes: 5120 * 1024 * 1024,
  leases: 512,
};

export type EpubSessionLimits = typeof DEFAULT_EPUB_SESSION_LIMITS;
