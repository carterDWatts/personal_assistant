import { handler } from "./handler.ts";
import { googleCallback } from "./connections.ts";
import { socket } from "./socket.ts";
import identity from "../../../identity.json" with { type: "json" };

const config = {
  url: Deno.env.get("SUPABASE_URL")!,
  anonKey: Deno.env.get("SUPABASE_ANON_KEY")!,
  serviceKey: Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  identity,
  credentialKey: Deno.env.get("ASSISTANT_CREDENTIAL_KEY"),
  googleClientId: Deno.env.get("GOOGLE_CLIENT_ID"),
  googleClientSecret: Deno.env.get("GOOGLE_CLIENT_SECRET"),
};
const http = handler(config);
Deno.serve((req) => req.method === "GET" && new URL(req.url).pathname.endsWith("/google/callback") ? googleCallback(req,config) : req.headers.get("upgrade")?.toLowerCase() === "websocket" ? socket(req, config) : http(req));
