import { handler } from "./handler.ts";
import { socket } from "./socket.ts";
import identity from "../../../identity.json" with { type: "json" };

const config = {
  url: Deno.env.get("SUPABASE_URL")!,
  anonKey: Deno.env.get("SUPABASE_ANON_KEY")!,
  serviceKey: Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  identity,
};
const http = handler(config);
Deno.serve((req) => req.headers.get("upgrade")?.toLowerCase() === "websocket" ? socket(req, config) : http(req));
