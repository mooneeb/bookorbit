import { Controller, Delete, Get, Param, ParseIntPipe, ParseUUIDPipe, Post, Res } from '@nestjs/common';
import type { FastifyReply } from 'fastify';
import { CurrentUser } from '../../../common/decorators/current-user.decorator';
import type { RequestUser } from '../../../common/types/request-user';
import { EpubSessionService } from './epub-session.service';

@Controller('epub-sessions')
export class EpubSessionController {
  constructor(private readonly sessions: EpubSessionService) {}

  @Post('books/:bookId/files/:fileId')
  open(@Param('bookId', ParseIntPipe) bookId: number, @Param('fileId', ParseIntPipe) fileId: number, @CurrentUser() user: RequestUser) {
    return this.sessions.open(bookId, fileId, user);
  }

  @Get(':id/original')
  async original(@Param('id', ParseUUIDPipe) id: string, @CurrentUser() user: RequestUser, @Res() reply: FastifyReply) {
    const resource = await this.sessions.original(id, user);
    reply.header('Cache-Control', 'private, no-store');
    reply.header('Content-Type', 'application/epub+zip');
    reply.header('Content-Length', resource.bytes);
    return reply.send(resource.stream);
  }

  @Get(':id/members/:index')
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
  heartbeat(@Param('id', ParseUUIDPipe) id: string, @CurrentUser() user: RequestUser) {
    return this.sessions.heartbeat(id, user);
  }

  @Delete(':id')
  close(@Param('id', ParseUUIDPipe) id: string, @CurrentUser() user: RequestUser) {
    return this.sessions.close(id, user);
  }
}
