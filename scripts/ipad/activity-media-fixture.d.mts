export interface ActivityMediaFixture {
  audioPath: string;
  epubPath: string;
  audioDurationSeconds: number;
  narrationDurationSeconds: number;
  paragraphWords: number;
  audioSHA256: string;
  epubSHA256: string;
  audioTitle: string;
  epubTitle: string;
  inputKind: string;
}

export const ACTIVITY_MEDIA_SECONDS: number;
export const ACTIVITY_AUDIO_TITLE: string;
export const ACTIVITY_EPUB_TITLE: string;
export const ACTIVITY_PARAGRAPH: string;
export function ensureActivityMediaFixture(folder: string): Promise<ActivityMediaFixture>;
export function inspectActivityMediaFixture(folder: string): Promise<ActivityMediaFixture>;
