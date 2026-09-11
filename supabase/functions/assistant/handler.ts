import { imageRequest } from './images.ts';
import { connection, connectionActions } from './connections.ts';
// Authentication is checked with Auth before the privileged RPC receives a user ID.
export type Config = { url: string; anonKey: string; serviceKey: string; identity?: { name: string }; credentialKey?: string; oauthApps?: Record<string, {id?: string; secret?: string}>; };
const actions = new Set(["work_updates", "start_routine", "alarm_sync", "alarm_receipt", "inbox", "inbox_open", "inbox_cancel", "image", "email","register", "bootstrap", "submit", "cancel", "events", "revoke", "clear", "import_part", "imports", "push_register", "reminder_action", "reminders", "notification_message"]);
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const headers = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Cache-Control": "no-store",
};
const reply = (body: unknown, status = 200) => Response.json(body, { status, headers });

async function body(req: Request) {
  const reader = req.body?.getReader();
  if (!reader) throw new Error("invalid_request");
  const chunks: Uint8Array[] = [];
  let size = 0;
  while (true) {
    const part = await reader.read();
    if (part.done) break;
    size += part.value.length;
    if (size > 5_400_000) {
      await reader.cancel();
      throw new Error("request_too_large");
    }
    chunks.push(part.value);
  }
  return JSON.parse(await new Blob(chunks.map(chunk => new Uint8Array(chunk).buffer)).text());
}

export function handler(config: Config, fetcher: typeof fetch = fetch) {
  return async (req: Request): Promise<Response> => {
    if (req.method === "OPTIONS") return new Response(null, { status: 204, headers });
    if (req.method !== "POST") return reply({ error: "method_not_allowed" }, 405);
    const authorization = req.headers.get("authorization") || "";
    if (!/^Bearer \S+$/i.test(authorization)) return reply({ error: "sign_in_required" }, 401);
    try {
      const auth = await fetcher(`${config.url}/auth/v1/user`, {
        headers: { authorization, apikey: config.anonKey }, signal: AbortSignal.timeout(10_000),
      });
      if (!auth.ok) return reply({ error: "sign_in_required" }, 401);
      const user = await auth.json();
      if (!uuid.test(user.id) || user.is_anonymous) return reply({ error: "sign_in_required" }, 401);
      const input = await body(req);
      return await execute(config, user.id, input, fetcher);
    } catch (error) {
      if (error instanceof SyntaxError) return reply({ error: "invalid_request" }, 400);
      if (error instanceof Error && ["request_too_large", "invalid_request"].includes(error.message)) {
        return reply({ error: error.message }, 400);
      }
      return reply({ error: "service_unavailable" }, 503);
    }
  };
}

export async function execute(config: Config, userId: string, input: any, fetcher: typeof fetch = fetch): Promise<Response> {
  if (!input || (!actions.has(input.action) && !connectionActions.has(input.action)) || !uuid.test(input.device_id) ||
      (input.args !== undefined && (!input.args || typeof input.args !== "object" || Array.isArray(input.args)))) {
    return reply({ error: "invalid_request" }, 400);
  }
  if (input.action !== 'image' && new TextEncoder().encode(JSON.stringify(input)).length > 140_000) return reply({error:'request_too_large'},400);
  if (connectionActions.has(input.action)) {
    try { return reply(await connection(config,userId,input,fetcher)); }
    catch (error) {
      const code = error instanceof Error ? error.message : '';
      if (['account_denied','device_denied'].includes(code)) return reply({error:code},403);
      if (['connection_rejected','invalid_request'].includes(code)) return reply({error:code},400);
      return reply({error:'connections_unavailable'},503);
    }
  }
  if (input.action === 'image') {
    try { return reply(await imageRequest(config,userId,input,fetcher)); }
    catch (error) { const code=error instanceof Error ? error.message : 'service_unavailable'; return reply({error:code},['account_denied','device_denied'].includes(code)?403:code==='invalid_request'?400:503); }
  }
  const email = input.action === 'email';
  if (email && !['list','get','approve','discard'].includes(input.args?.operation)) return reply({error:'invalid_request'},400);
  const response = await fetcher(`${config.url}/rest/v1/rpc/${email ? 'assistant_email' : 'assistant_client'}`, {
    method: "POST",
    headers: { "Content-Type": "application/json", apikey: config.serviceKey,
      authorization: `Bearer ${config.serviceKey}` },
    body: JSON.stringify({ p_user: userId, p_device: input.device_id, p_action: email ? input.args.operation : input.action, p_args: input.args || {} }),
    signal: AbortSignal.timeout(15_000),
  });
  const result = await response.json();
  if (response.ok) return reply(input.action === 'bootstrap' && config.identity ?
    { ...result, identity: config.identity } : result);
  const code = result.message;
  if (["account_denied", "device_denied"].includes(code)) return reply({ error: code }, 403);
  if (["conversation_busy", "idempotency_conflict"].includes(code)) return reply({ error: code }, 409);
  if (['draft_changed','draft_locked','draft_expired'].includes(code)) return reply({error:code},409);
  if (code === "turn_not_found") return reply({ error: code }, 404);
  if (["model_unavailable", "speech_unavailable"].includes(code)) return reply({ error: code }, 400);
  if (["22P02", "23502", "23514", "22023"].includes(result.code)) return reply({ error: "invalid_request" }, 400);
  return reply({ error: "service_unavailable" }, 503);
}
