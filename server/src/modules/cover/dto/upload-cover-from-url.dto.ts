import { IsUrl } from 'class-validator';
import type { UploadCoverFromUrlPayload } from '@bookorbit/types';

export class UploadCoverFromUrlDto implements UploadCoverFromUrlPayload {
  @IsUrl({ protocols: ['http', 'https'], require_tld: true })
  url: string;
}
