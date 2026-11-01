import { Body, Controller, Delete, Get, Param, ParseIntPipe, ParseUUIDPipe, Post, Res } from '@nestjs/common';
import type { FastifyReply } from 'fastify';
import { CurrentUser } from '../../../common/decorators/current-user.decorator';
import type { RequestUser } from '../../../common/types/request-user';
import { EpubSessionService } from './epub-session.service';
import { RequirePermission } from '../../../common/decorators/require-permission.decorator';
import { Permission } from '@bookorbit/types';
import { PrepareEpubDto } from './dto/prepare-epub.dto';

@Controller('epub-sessions')
export class EpubSessionController {
  constructor(private readonly sessions: EpubSessionService) {}

  @Post('books/:bookId/files/:fileId')
  @RequirePermission(Permission.LibraryDownload)
  open(
    @Param('bookId', ParseIntPipe) bookId: number,
    @Param('fileId', ParseIntPipe) fileId: number,
    @CurrentUser() user: RequestUser,
    @Body() body: PrepareEpubDto,
  ) {
    void body;
    return this.sessions.open(bookId, fileId, user);
  }

  @Get('capabilities')
  capabilities(@CurrentUser() user: RequestUser) {
    return this.sessions.capabilities(user);
  }

  @Get(':id/original')
  @RequirePermission(Permission.LibraryDownload)
  async original(@Param('id', ParseUUIDPipe) id: string, @CurrentUser() user: RequestUser, @Res() reply: FastifyReply) {
    const resource = await this.sessions.original(id, user);
    reply.header('Cache-Control', 'private, no-store');
    reply.header('Content-Type', 'application/epub+zip');
    reply.header('Content-Length', resource.bytes);
    return reply.send(resource.stream);
  }

  @Get(':id/members/:index')
  @RequirePermission(Permission.LibraryDownload)
  async member(
    @Param('id', ParseUUIDPipe) id: string,
    @Param('index', ParseIntPipe) index: number,
    @CurrentUser() user: RequestUser,
    @Res() reply: FastifyReply,
  ) {
    const resource = await this.sessions.resource(id, index, user);
    reply.header('Cache-Control', 'private, no-store');
    reply.header('Content-Type', 'application/octet-stream');
    reply.header('Content-Length', resource.bytes);
    return reply.send(resource.stream);
  }

  @Post(':id/heartbeat')
  @RequirePermission(Permission.LibraryDownload)
  heartbeat(@Param('id', ParseUUIDPipe) id: string, @CurrentUser() user: RequestUser) {
    return this.sessions.heartbeat(id, user);
  }

  @Delete(':id')
  @RequirePermission(Permission.LibraryDownload)
  close(@Param('id', ParseUUIDPipe) id: string, @CurrentUser() user: RequestUser) {
    return this.sessions.close(id, user);
  }
}
