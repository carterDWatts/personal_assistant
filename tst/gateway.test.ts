import { test } from 'node:test';
import assert from 'node:assert/strict';
import { handler } from '../supabase/functions/assistant/handler.ts';

const owner = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
const device = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb';
const config = { url: 'https://example.invalid', anonKey: 'public', serviceKey: 'private' };
const request = (data: unknown) => new Request('https://example.invalid', {
  method: 'POST', headers: { authorization: 'Bearer user-session' }, body: JSON.stringify(data),
});

test('unverified callers never reach the database', async () => {
  let calls = 0;
  const run = handler(config, async () => { calls++; return new Response(null, { status: 401 }); });
  assert.equal((await run(request({ action: 'bootstrap', device_id: device }))).status, 401);
  assert.equal(calls, 1);
});

test('identity comes from Auth, never from the request', async () => {
  let calls = 0;
  const run = handler(config, async (url, options) => {
    if (++calls === 1) return Response.json({ id: owner });
    const body = JSON.parse(String(options?.body));
    assert.equal(body.p_user, owner);
    assert.equal(body.p_device, device);
    assert.equal(new Headers(options?.headers).get('authorization'), 'Bearer private');
    return Response.json({ history: [] });
  });
  const result = await run(request({ action: 'bootstrap', device_id: device, user_id: device }));
  assert.equal(result.status, 200);
  assert.deepEqual(await result.json(), { history: [] });
});

test('SQL errors cannot expose internal data', async () => {
  let calls = 0;
  const run = handler(config, async () => ++calls === 1 ? Response.json({ id: owner }) :
    Response.json({ message: 'password=secret', details: 'private records' }, { status: 500 }));
  const response = await run(request({ action: 'bootstrap', device_id: device }));
  assert.equal(response.status, 503);
  assert.deepEqual(await response.json(), { error: 'service_unavailable' });
});

test('unknown commands and oversized requests never reach SQL', async () => {
  let calls = 0;
  const run = handler(config, async () => { calls++; return Response.json({ id: owner }); });
  assert.equal((await run(request({ action: 'execute_sql', device_id: device }))).status, 400);
  assert.equal((await run(request({ action: 'submit', device_id: device, args: { text: 'x'.repeat(140_000) } }))).status, 400);
  assert.equal(calls, 2);
});

test('bootstrap identity comes from the shared configuration', async () => {
  let calls = 0;
  const run = handler({ ...config, identity: { name: 'New name' } }, async () =>
    Response.json(++calls === 1 ? { id: owner } : { day: { plans: [] } }));
  const response = await run(request({ action: 'bootstrap', device_id: device }));
  assert.equal((await response.json()).identity.name, 'New name');
});

test('clear is dispatched with the verified owner and stable request ID', async () => {
  let calls = 0;
  const run = handler(config, async (_url, options) => {
    if (++calls === 1) return Response.json({ id: owner });
    const body = JSON.parse(String(options?.body));
    assert.equal(body.p_action, 'clear');
    assert.equal(body.p_user, owner);
    assert.equal(body.p_args.request_id, device);
    return Response.json({ status: 'cleared', cutoff: 12 });
  });
  const response = await run(request({ action: 'clear', device_id: device, args: { request_id: device } }));
  assert.equal(response.status, 200);
  assert.equal((await response.json()).status, 'cleared');
});

test('unauthenticated and expired sockets cannot upgrade or call SQL', async () => {
  const { socket } = await import('../supabase/functions/assistant/socket.ts');
  let calls = 0;
  const auth = async () => { calls++; return Response.json({ id: owner }); };
  assert.equal((await socket(new Request('https://example.invalid'), config, auth)).status, 401);
  assert.equal(calls, 0);
  const expired = 'header.' + btoa(JSON.stringify({ exp: 1 })) + '.signature';
  const req = new Request('https://example.invalid', { headers: { authorization: 'Bearer ' + expired } });
  assert.equal((await socket(req, config, auth)).status, 401);
  assert.equal(calls, 1);
});


test('live event waits preserve the cursor and return the first available page', async () => {
  const { receive } = await import('../supabase/functions/assistant/socket.ts');
  let calls = 0;
  const result = await receive(config, owner, { action: 'events', device_id: device, args: { after: 42, wait: true } },
    async (_url, options) => {
      const body = JSON.parse(String(options?.body));
      assert.equal(body.p_user, owner);
      assert.equal(body.p_args.after, 42);
      return Response.json({ events: ++calls < 3 ? [] : [{ cursor: 43 }], has_more: false });
    });
  assert.equal(calls, 3);
  assert.deepEqual(result.body.events, [{ cursor: 43 }]);
});

test('revocation stops a live event wait without exposing the SQL error', async () => {
  const { receive } = await import('../supabase/functions/assistant/socket.ts');
  let calls = 0;
  const result = await receive(config, owner, { action: 'events', device_id: device, args: { wait: true } },
    async () => ++calls === 1 ? Response.json({ events: [] }) :
      Response.json({ message: 'device_denied' }, { status: 403 }));
  assert.equal(calls, 2);
  assert.deepEqual(result, { status: 403, body: { error: 'device_denied' } });
});

test('idle reads and closed sockets do not wait', async () => {
  const { receive } = await import('../supabase/functions/assistant/socket.ts');
  let calls = 0;
  const read = async () => { calls++; return Response.json({ events: [] }); };
  await receive(config, owner, { action: 'events', device_id: device }, read);
  await receive(config, owner, { action: 'events', device_id: device, args: { wait: true } }, read, () => false);
  assert.equal(calls, 2);
});

import { connection, googleCallback } from '../supabase/functions/assistant/connections.ts';
const connectedConfig = {...config, credentialKey: btoa('k'.repeat(32)), googleClientId:'client', googleClientSecret:'secret'};

test('Google callback exchanges PKCE and stores encrypted credentials only once', async () => {
  let saved: any, intent: any, state: string, consumed = false;
  const fetcher: typeof fetch = async (url, options) => {
    if (String(url).includes('/rpc/')) {
      const body = JSON.parse(String(options?.body));
      if (body.p_action === 'list') return Response.json([]);
      if (body.p_action === 'begin') { intent={...body.p_args,id:device,user_id:owner,device_id:device}; return Response.json({intent_id:device}); }
      if (body.p_action === 'claim') {
        if (consumed) return Response.json({message:'invalid_request'},{status:400});
        consumed=true; return Response.json(intent);
      }
      if (body.p_action === 'complete') { saved=body.p_args; return Response.json({}); }
      throw new Error('Unexpected database action');
    }
    if (String(url).endsWith('/token')) {
      assert.ok(new URLSearchParams(String(options?.body)).get('code_verifier'));
      return Response.json({refresh_token:'refresh-secret',access_token:'access-secret',expires_in:3600,scope:'https://www.googleapis.com/auth/calendar.readonly https://www.googleapis.com/auth/gmail.readonly'});
    }
    return Response.json({email:'test@example.com'});
  };
  const result=await connection(connectedConfig,owner,{device_id:device,action:'connection_start',args:{provider:'google',grant:'calendar'}},fetcher);
  const auth=new URL(result.url); state=auth.searchParams.get('state')!;
  assert.equal(auth.searchParams.get('code_challenge_method'),'S256');
  const callback=new Request(`https://example.invalid?state=${state}&code=code`);
  assert.match((await googleCallback(callback,connectedConfig,fetcher)).headers.get('location')!,/status=connected/);
  assert.equal(saved.metadata.account,'test@example.com');
  assert.ok(!JSON.stringify(saved).includes('refresh-secret'));
  assert.match((await googleCallback(callback,connectedConfig,fetcher)).headers.get('location')!,/status=failed/);
});

test('revoked connections cannot contact providers and rejected tokens are not saved', async () => {
  let calls=0;
  await assert.rejects(connection(connectedConfig,owner,{device_id:device,action:'connection_token',args:{provider:'github',token:'secret'}},async()=>{
    calls++;return Response.json({message:'device_denied'},{status:403});
  }),/device_denied/);
  assert.equal(calls,1);
  calls=0;
  await assert.rejects(connection(connectedConfig,owner,{device_id:device,action:'connection_token',args:{provider:'github',token:'secret'}},async()=>{
    calls++;return calls===1?Response.json([]):new Response(null,{status:401});
  }),/connection_rejected/);
  assert.equal(calls,2);
});
