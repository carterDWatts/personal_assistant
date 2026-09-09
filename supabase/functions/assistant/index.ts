import { handler } from "./handler.ts";
import { googleCallback, accountCallback } from "./connections.ts";
import { integrations, oauthProviders } from './catalog.ts';
import { socket } from "./socket.ts";
import identity from "../../../identity.json" with { type: "json" };

const config = {
  url: Deno.env.get("SUPABASE_URL")!,
  anonKey: Deno.env.get("SUPABASE_ANON_KEY")!,
  serviceKey: Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  identity,
  credentialKey: Deno.env.get("ASSISTANT_CREDENTIAL_KEY"),
  oauthApps: Object.fromEntries(integrations.filter(item => item.oauth).map(item => [item.id, {
    id: Deno.env.get(item.oauth!.clientIdEnv), secret: Deno.env.get(item.oauth!.clientSecretEnv),
  }])),
};
const http = handler(config);
Deno.serve((req) => {
  const path=new URL(req.url).pathname;
  if (req.method==='GET') {
    if (path.endsWith('/google/callback')) return googleCallback(req,config);
    const provider = oauthProviders.find(item => path.endsWith('/'+item.id+'/callback'));
    if (provider) return accountCallback(req,config,provider.id);
  }
  return req.headers.get('upgrade')?.toLowerCase()==='websocket' ? socket(req,config) : http(req);
});
