import { IsString, MaxLength, MinLength } from 'class-validator';
import { AuthClientDto } from './auth-client.dto';

export class MagicLinkLoginDto extends AuthClientDto {
  @IsString()
  @MinLength(1)
  @MaxLength(512)
  token: string;
}
