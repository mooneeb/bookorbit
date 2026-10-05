import { AuthClientDto } from './auth-client.dto';
import { IsNotEmpty, IsString, MaxLength } from 'class-validator';
import type { LoginRequest } from '@bookorbit/types';

export class LoginDto extends AuthClientDto implements LoginRequest {
  @IsString()
  @IsNotEmpty()
  @MaxLength(100)
  username: string;

  @IsString()
  @IsNotEmpty()
  @MaxLength(1024)
  password: string;
}
