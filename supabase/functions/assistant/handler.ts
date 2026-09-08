// Authentication is checked with Auth before the privileged RPC receives a user ID.
type Config = { url: string; anonKey: string; serviceKey: string; identity?: { name: string } };
const actions = new Set(["register", "bootstrap", "submit", "cancel", "events", "revoke", "clear"]);
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
    if (size > 140_000) {
      await reader.cancel();
      throw new Error("request_too_large");
    }
    chunks.push(part.value);
  }
  return JSON.parse(await new Blob(chunks).text());
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
      if (!input || !actions.has(input.action) || !uuid.test(input.device_id) ||
          (input.args !== undefined && (!input.args || typeof input.args !== "object" || Array.isArray(input.args)))) {
        return reply({ error: "invalid_request" }, 400);
      }
      const response = await fetcher(`${config.url}/rest/v1/rpc/assistant_client`, {
        method: "POST",
        headers: { "Content-Type": "application/json", apikey: config.serviceKey,
          authorization: `Bearer ${config.serviceKey}` },
        body: JSON.stringify({ p_user: user.id, p_device: input.device_id, p_action: input.action, p_args: input.args || {} }),
        signal: AbortSignal.timeout(15_000),
      });
      const result = await response.json();
      if (response.ok) return reply(input.action === 'bootstrap' && config.identity ?
        { ...result, identity: config.identity } : result);
      const code = result.message;
      if (["account_denied", "device_denied"].includes(code)) return reply({ error: code }, 403);
      if (["conversation_busy", "idempotency_conflict"].includes(code)) return reply({ error: code }, 409);
      if (code === "turn_not_found") return reply({ error: code }, 404);
      if (["22P02", "23502", "23514", "22023"].includes(result.code)) return reply({ error: "invalid_request" }, 400);
      return reply({ error: "service_unavailable" }, 503);
    } catch (error) {
      if (error instanceof SyntaxError) return reply({ error: "invalid_request" }, 400);
      if (error instanceof Error && ["request_too_large", "invalid_request"].includes(error.message)) {
        return reply({ error: error.message }, 400);
      }
      return reply({ error: "service_unavailable" }, 503);
    }
  };
}
