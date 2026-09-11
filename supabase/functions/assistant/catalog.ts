import catalog from '../../../shared/integrations.json' with { type: 'json' };
import type { Config } from './handler.ts';

type OAuth = {authorize: string; token: string; clientAuth: string; pkce?: boolean; tokenEncoding?: string; parameters: Record<string,string>; clientIdEnv: string; clientSecretEnv: string};
type Grant = {id: string; action: string; slot: string; name: string; description: string; scopes: string[]};
type Provider = {id: string; name: string; auth: string; action: string; capabilities: string[]; grants: Grant[]; apiBase?: string; profile?: string; headers?: Record<string,string>; oauth?: OAuth};
if (catalog.version !== 1) throw new Error('Unsupported integration catalog version');
export const integrations = catalog.providers as Provider[];
export const google = integrations.find(item => item.id === 'google')!;
export const grants = Object.fromEntries(google.grants.map(item => [item.id, item]));
export const providers = Object.fromEntries(integrations.filter(item => item.id !== 'google').map(item =>
  [item.id, {...item, url: item.apiBase! + item.profile!, headers: {'User-Agent':'personal-assistant', ...item.headers}}]));
export const oauthProviders = integrations.filter(item => item.id !== 'google' && item.auth === 'oauth');

export function registration(config: Config, provider: string) {
  const details = integrations.find(item => item.id === provider)?.oauth;
  if (!details) throw new Error('invalid_request');
  const id = config.oauthApps?.[provider]?.id;
  const secret = config.oauthApps?.[provider]?.secret;
  if (!id || (!secret && details.clientAuth !== 'pkce') || !config.credentialKey) throw new Error('connections_unavailable');
  return {...details, id, secret:secret || ''};
}

export function configured(config: Config, provider: Provider) {
  if (!config.credentialKey) return false;
  if (provider.auth === 'token') return true;
  try { registration(config, provider.id); return true; } catch { return false; }
}
