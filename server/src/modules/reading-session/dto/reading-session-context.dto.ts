import type { NativeReadingSessionContext } from '@bookorbit/types';

export class ReadingSessionContextDto implements NativeReadingSessionContext {
  bookId!: number;
  attemptId!: number | null;
}
