import { type Config, execute } from "./handler.ts";

// Keep one authenticated connection open for live turns. Device authorization is
// still checked by the RPC on every request; no client-supplied user ID is used.
export async function socket(req: Request, config: Config, fetcher: typeof fetch = fetch): Promise<Response> {
  const authorization = req.headers.get("authorization") || "";
  if (!/^Bearer \S+$/i.test(authorization)) return new Response(null, { status: 401 });
  let user;
  let expires: number;
  try {
    const auth = await fetcher(`${config.url}/auth/v1/user`, {
      headers: { authorization, apikey: config.anonKey }, signal: AbortSignal.timeout(10_000),
    });
    if (!auth.ok) return new Response(null, { status: 401 });
    user = await auth.json();
    if (!user.id || user.is_anonymous) return new Response(null, { status: 401 });
    // Auth verified the token above. Never keep a socket past its token expiry.
    const encoded = authorization.split(" ")[1].split(".")[1].replaceAll("-", "+").replaceAll("_", "/");
    expires = JSON.parse(atob(encoded)).exp * 1000;
    if (!Number.isFinite(expires) || expires <= Date.now()) return new Response(null, { status: 401 });
  } catch { return new Response(null, { status: 503 }); }
  const { socket, response } = Deno.upgradeWebSocket(req);
  let pending = 0;
  const timer = setTimeout(() => socket.close(1000, "Reconnect"), Math.min(110_000, expires - Date.now()));
  socket.onclose = () => clearTimeout(timer);
  socket.onerror = () => clearTimeout(timer);
  socket.onmessage = async (message) => {
    if (typeof message.data !== "string" || message.data.length > 140_000 || pending >= 8) {
      socket.close(1008, "Invalid request"); return;
    }
    pending += 1;
    try {
      const input = JSON.parse(message.data);
      if (typeof input.id !== "string" || input.id.length > 64) { socket.close(1008); return; }
      const result = await receive(config, user.id, input, fetcher, () => socket.readyState === WebSocket.OPEN);
      if (socket.readyState === WebSocket.OPEN) socket.send(JSON.stringify({ id: input.id, ...result }));
      if (result.status === 403) socket.close(1008, "Access denied");
    } catch {
      if (socket.readyState === WebSocket.OPEN) socket.close(1011, "Request failed");
    } finally { pending -= 1; }
  };
  return response;
}

// Wait near the database for live events, rather than making the phone complete
// an empty round trip before it can ask again. Every read rechecks device access.
export async function receive(config: Config, userId: string, input: any,
  fetcher: typeof fetch = fetch, connected = () => true) {
  const deadline = Date.now() + (input.action === "events" && input.args?.wait === true ? 1000 : 0);
  while (true) {
    const response = await execute(config, userId, input, fetcher);
    const body = await response.json();
    if (!response.ok || body.events?.length || Date.now() >= deadline || !connected()) {
      return { status: response.status, body };
    }
    await new Promise(resolve => setTimeout(resolve, 30));
  }
}
