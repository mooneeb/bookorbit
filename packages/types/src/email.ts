export interface EmailProvider {
  id: number;
  userId: number | null;
  name: string;
  host: string;
  port: number;
  username: string | null;
  fromName: string | null;
  fromAddress: string | null;
  auth: boolean;
  ssl: boolean;
  startTls: boolean;
  tlsRejectUnauthorized: boolean;
  isDefault: boolean;
  isShared: boolean;
  isSystemProvider: boolean;
  hasPassword: boolean;
  createdAt: string;
}
export interface EmailRecipient {
  id: number;
  userId: number;
  name: string;
  email: string;
  isDefault: boolean;
  deviceType: string | null;
  preferredFormat: string | null;
  defaultTemplateId: number | null;
  createdAt: string;
}
export interface EmailPreferences {
  userId: number;
  defaultProviderId: number | null;
  defaultRecipientId: number | null;
  defaultTemplateId: number | null;
}
export interface EmailSendLogEntry {
  id: number;
  userId: number;
  bookId: number | null;
  bookFileId: number | null;
  providerId: number | null;
  templateId: number | null;
  toEmail: string;
  toName: string | null;
  subject: string | null;
  status: "pending" | "sent" | "failed";
  attemptCount: number;
  errorMessage: string | null;
  nextRetryAt: string | null;
  sentAt: string | null;
  createdAt: string;
}
export interface CreateEmailProviderPayload {
  name: string;
  host: string;
  port: number;
  username?: string;
  password?: string;
  fromName?: string;
  fromAddress?: string;
  auth: boolean;
  ssl: boolean;
  startTls: boolean;
  tlsRejectUnauthorized: boolean;
}
export interface CreateEmailRecipientPayload {
  name: string;
  email: string;
  deviceType?: string;
  preferredFormat?: string;
  defaultTemplateId?: number;
}
export interface UpdateEmailPreferencesPayload {
  defaultProviderId?: number | null;
  defaultRecipientId?: number | null;
  defaultTemplateId?: number | null;
}
export interface EmailSelectedBookSendPayload {
  bookIds: number[];
  recipientIds: number[];
  fileId: number;
  providerId?: number;
  templateId?: number;
}
export interface EmailSendAcceptedResponse {
  queued: number;
  /** The first 100 queued job IDs, keeping responses bounded for bulk sends. */
  logIds: number[];
}
export interface EmailProviderTestResponse {
  success: boolean;
  error?: string;
}
