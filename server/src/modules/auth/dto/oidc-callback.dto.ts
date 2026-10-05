import { AuthClientDto } from './auth-client.dto';
import { IsNotEmpty, IsString, MaxLength } from 'class-validator';
import type { OidcCallbackRequest } from '@bookorbit/types';

export class OidcCallbackDto extends AuthClientDto implements OidcCallbackRequest {
  @IsString()
  @IsNotEmpty()
  @MaxLength(2048)
  code: string;

  @IsString()
  @IsNotEmpty()
  @MaxLength(2048)
  codeVerifier: string;

  @IsString()
  @IsNotEmpty()
  @MaxLength(2048)
  redirectUri: string;

  @IsString()
  @IsNotEmpty()
  @MaxLength(512)
  nonce: string;

  @IsString()
  @IsNotEmpty()
  @MaxLength(512)
  state: string;
}
