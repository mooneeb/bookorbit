import { IsBoolean } from 'class-validator';
import type { SetSmartScopeKoboSyncPayload } from '@bookorbit/types';

export class SetKoboSyncDto implements SetSmartScopeKoboSyncPayload {
  @IsBoolean()
  enabled: boolean;
}
