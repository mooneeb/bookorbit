import { IsEmail } from 'class-validator';
import type { ForgotPasswordRequest } from '@bookorbit/types';

export class ForgotPasswordDto implements ForgotPasswordRequest {
  @IsEmail()
  email: string;
}
