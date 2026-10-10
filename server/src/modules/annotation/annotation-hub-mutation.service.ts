import { BadRequestException, Injectable } from '@nestjs/common';
import { randomUUID } from 'node:crypto';
import type { AnnotationPositionFormat, NativeAnnotationItem } from '@bookorbit/types';

import type { RequestUser } from '../../common/types/request-user';
import { AnnotationHubService } from './annotation-hub.service';
import { NativeAnnotationService } from './native-annotation.service';
import type { AnnotationBulkDto } from './dto/annotation-hub.dto';

@Injectable()
export class AnnotationHubMutationService {
  constructor(
    private readonly hubService: AnnotationHubService,
    private readonly nativeAnnotations: NativeAnnotationService,
  ) {}

  async bulk(user: RequestUser, dto: AnnotationBulkDto): Promise<{ affected: number }> {
    const versioned: NativeAnnotationItem[] = [];
    for (let offset = 0; offset < dto.ids.length; offset += 100) {
      versioned.push(
        ...(await this.nativeAnnotations.getItems(dto.ids.slice(offset, offset + 100), user.id)).filter((item) => item.clientId != null),
      );
    }
    if (versioned.length && (dto.action === 'trash' || dto.action === 'restore')) {
      const result = await this.nativeAnnotations.operations(user, {
        deviceId: 'web-annotation-hub',
        operations: versioned.map((item) => ({
          operationId: randomUUID(),
          clientId: item.clientId!,
          annotationId: item.id,
          bookId: item.bookId,
          baseVersion: item.version,
          action: dto.action === 'trash' ? 'delete' : 'restore',
        })),
      });
      const versionedIds = new Set(versioned.map((item) => item.id));
      const legacy = await this.hubService.bulk(user.id, { ...dto, ids: dto.ids.filter((id) => !versionedIds.has(id)) });
      return { affected: legacy.affected + result.results.filter((item) => item.status === 'applied').length };
    }
    return this.hubService.bulk(user.id, dto);
  }

  async restore(user: RequestUser, annotationId: number) {
    const item = await this.nativeAnnotations.getItem(annotationId, user.id);
    if (item?.clientId) {
      const result = await this.nativeAnnotations.operations(user, {
        deviceId: 'web-annotation-hub',
        operations: [
          { operationId: randomUUID(), clientId: item.clientId, annotationId, bookId: item.bookId, baseVersion: item.version, action: 'restore' },
        ],
      });
      return result.results[0]?.annotation;
    }
    return this.hubService.restore(user.id, annotationId);
  }

  async retryPosition(user: RequestUser, annotationId: number, format: AnnotationPositionFormat) {
    const item = await this.nativeAnnotations.getItem(annotationId, user.id);
    if (item?.kind === 'pdf_ink') throw new BadRequestException('Source PDF ink must use versioned anchor repair');
    return this.hubService.retryPosition(user.id, annotationId, format);
  }
}
