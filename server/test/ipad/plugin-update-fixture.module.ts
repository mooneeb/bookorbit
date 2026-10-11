import { BadRequestException, Body, Controller, Delete, ForbiddenException, Global, HttpCode, Injectable, Module, Param, Post } from '@nestjs/common';
import { IsObject, IsString, MaxLength } from 'class-validator';
import { Permission } from '@bookorbit/types';

import { CurrentUser } from '../../src/common/decorators/current-user.decorator';
import { RequirePermission } from '../../src/common/decorators/require-permission.decorator';
import type { RequestUser } from '../../src/common/types/request-user';
import { safeFetch } from '../../src/common/utils/safe-fetch';
import { MAX_PLUGIN_BYTES } from '../../src/modules/book-request/indexers/plugins/plugin-install.service';
import { PLUGIN_UPDATE_FETCH, type PluginUpdateFetch } from '../../src/modules/book-request/indexers/plugins/plugin-update.service';

const FIXTURE_HOST = 'e03-plugin-updates.invalid';
const MAX_MANIFEST_BYTES = 64 * 1024;
const MAX_FIXTURES = 16;

class SignedPluginProviderFixtureDto {
  @IsString()
  @MaxLength(MAX_PLUGIN_BYTES)
  source!: string;

  @IsObject()
  manifest!: Record<string, unknown>;
}

@Injectable()
class SignedPluginProviderFixture {
  private readonly fixtures = new Map<string, { source: string; manifest: string }>();

  register(id: string, value: SignedPluginProviderFixtureDto): void {
    this.requireID(id);
    const manifest = JSON.stringify(value.manifest);
    if (Buffer.byteLength(value.source) > MAX_PLUGIN_BYTES || Buffer.byteLength(manifest) > MAX_MANIFEST_BYTES) {
      throw new BadRequestException('The controlled plugin provider payload is too large');
    }
    if (!this.fixtures.has(id) && this.fixtures.size >= MAX_FIXTURES) throw new BadRequestException('Too many controlled plugin providers');
    this.fixtures.set(id, { source: value.source, manifest });
  }

  remove(id: string): void {
    this.requireID(id);
    this.fixtures.delete(id);
  }

  readonly fetchUpdate: PluginUpdateFetch = async (rawUrl, init = {}, options = {}) => {
    let url: URL;
    try {
      url = new URL(rawUrl);
    } catch {
      return safeFetch(rawUrl, init, options);
    }
    const match = /^\/([a-z0-9][a-z0-9-]{0,79})\/(plugin\.json|index\.mjs)$/.exec(url.pathname);
    const fixture = match ? this.fixtures.get(match[1]!) : undefined;
    if (
      !fixture ||
      !match ||
      url.protocol !== 'https:' ||
      url.hostname !== FIXTURE_HOST ||
      url.port ||
      url.username ||
      url.password ||
      url.search ||
      url.hash ||
      (init.method ?? 'GET') !== 'GET' ||
      !options.pinResolvedAddress
    ) {
      return safeFetch(rawUrl, init, options);
    }
    init.signal?.throwIfAborted();
    return new Response(match[2] === 'plugin.json' ? fixture.manifest : fixture.source, {
      headers: { 'content-type': match[2] === 'plugin.json' ? 'application/json' : 'text/javascript' },
    });
  };

  private requireID(id: string): void {
    if (!/^[a-z0-9][a-z0-9-]{0,79}$/.test(id)) throw new BadRequestException('Invalid controlled plugin provider ID');
  }
}

@Controller('__fixtures/plugin-updates')
@RequirePermission(Permission.ManageAppSettings)
class SignedPluginProviderFixtureController {
  constructor(private readonly provider: SignedPluginProviderFixture) {}

  @Post(':id')
  register(@CurrentUser() user: RequestUser, @Param('id') id: string, @Body() value: SignedPluginProviderFixtureDto) {
    this.owner(user);
    this.provider.register(id, value);
    return { origin: `https://${FIXTURE_HOST}/${id}` };
  }

  @Delete(':id')
  @HttpCode(204)
  remove(@CurrentUser() user: RequestUser, @Param('id') id: string): void {
    this.owner(user);
    this.provider.remove(id);
  }

  private owner(user: RequestUser): void {
    if (!user.isSuperuser) throw new ForbiddenException('Controlled plugin providers require the isolated harness owner');
  }
}

@Global()
@Module({
  providers: [
    SignedPluginProviderFixture,
    {
      provide: PLUGIN_UPDATE_FETCH,
      useFactory: (provider: SignedPluginProviderFixture) => provider.fetchUpdate,
      inject: [SignedPluginProviderFixture],
    },
  ],
  controllers: [SignedPluginProviderFixtureController],
  exports: [PLUGIN_UPDATE_FETCH],
})
export class PluginUpdateFixtureModule {}
