import { handler } from "./handler.ts";
import identity from "../../../identity.json" with { type: "json" };

Deno.serve(handler({
  url: Deno.env.get("SUPABASE_URL")!,
  anonKey: Deno.env.get("SUPABASE_ANON_KEY")!,
  serviceKey: Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  identity,
}));
