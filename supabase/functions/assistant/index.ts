import { handler } from "./handler.ts";
import { googleCallback, accountCallback } from "./connections.ts";
import { socket } from "./socket.ts";
import identity from "../../../identity.json" with { type: "json" };

const config = {
  url: Deno.env.get("SUPABASE_URL")!,
  anonKey: Deno.env.get("SUPABASE_ANON_KEY")!,
  serviceKey: Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  identity,
  githubClientId: Deno.env.get("GITHUB_CLIENT_ID"),
  githubClientSecret: Deno.env.get("GITHUB_CLIENT_SECRET"),
  supabaseClientId: Deno.env.get("SUPABASE_OAUTH_CLIENT_ID"),
  supabaseClientSecret: Deno.env.get("SUPABASE_OAUTH_CLIENT_SECRET"),
  credentialKey: Deno.env.get("ASSISTANT_CREDENTIAL_KEY"),
  googleClientId: Deno.env.get("GOOGLE_CLIENT_ID"),
  googleClientSecret: Deno.env.get("GOOGLE_CLIENT_SECRET"),
};
const http = handler(config);
Deno.serve((req) => {
  const path=new URL(req.url).pathname;
  if (req.method==='GET') {
    if (path.endsWith('/google/callback')) return googleCallback(req,config);
    if (path.endsWith('/github/callback')) return accountCallback(req,config,'github');
    if (path.endsWith('/supabase/callback')) return accountCallback(req,config,'supabase');
  }
  return req.headers.get('upgrade')?.toLowerCase()==='websocket' ? socket(req,config) : http(req);
});
