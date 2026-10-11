import type { OidcAutoProvision, OidcClaimMapping } from "./auth";
import type { OrganizationMode } from "./library";
import type { Permission } from "./permissions";
import type { ProviderStatus } from "./metadata-preferences";

export interface AdminUserListItem {
  id: number;
  username: string;
  name: string;
  email: string | null;
  active: boolean;
  isSuperuser: boolean;
  isDefaultPassword: boolean;
  lockedUntil: string | null;
  failedLoginAttempts: number;
  provisioningMethod: string;
  avatarUrl: string | null;
  createdAt: string;
  lastAuthenticatedAt: string | null;
  permissions: Permission[];
  hasContentFilters: boolean;
  libraryAccessCount: number;
}

export interface AdminUserListPage {
  users: AdminUserListItem[];
  total: number;
}

export interface AdminCreateUserRequest {
  username: string;
  name: string;
  email: string;
  permissionNames?: Permission[];
  libraryIds?: number[];
}

export interface AdminUpdateUserRequest {
  name?: string;
  email?: string;
  active?: boolean;
}

export interface AdminSetPermissionsRequest {
  permissionNames: Permission[];
}

export interface AdminLibraryRequest {
  name: string;
  icon: string;
  folders: string[];
  watch?: boolean;
  organizationMode?: OrganizationMode;
  autoScanCronExpression?: string | null;
  fileNamingPattern?: string | null;
  fileWriteEnabled?: boolean;
  fileRenameEnabled?: boolean;
}

export interface AdminOidcProviderRequest {
  slug: string;
  displayName: string;
  issuerUri: string;
  clientId: string;
  clientSecret?: string;
  enabled?: boolean;
  scopes?: string;
  iconUrl?: string;
  claimMapping?: OidcClaimMapping;
  autoProvision?: OidcAutoProvision;
}

export interface AdminTtsProvider {
  id: number;
  name: string;
  baseUrl: string | null;
  enabled: boolean;
  defaultModel: string | null;
  supportsVoiceDiscovery: boolean;
}

export interface AdminTtsProviderRequest {
  name: string;
  baseUrl: string;
  apiKey?: string;
  defaultModel?: string;
  supportsVoiceDiscovery?: boolean;
}

export interface AdminUpdateTtsProviderRequest {
  name?: string;
  baseUrl?: string;
  apiKey?: string;
  defaultModel?: string;
  enabled?: boolean;
  supportsVoiceDiscovery?: boolean;
}

export interface ProfileUpdateRequest {
  name?: string;
}

export interface AdminMetadataProviderStatusResponse {
  statuses: ProviderStatus[];
}
