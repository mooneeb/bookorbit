import { IsIn } from 'class-validator';

import type { ReadAloudProgressSyncMode, UpdateBookReadAloudSyncPayload } from '@bookorbit/types';

export class UpdateReadAloudSyncSettingsDto implements UpdateBookReadAloudSyncPayload {
  @IsIn(['auto', 'disabled'])
  mode!: ReadAloudProgressSyncMode;
}
