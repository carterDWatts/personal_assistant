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

test('foreground work updates use the authenticated client boundary', async () => {
  let calls = 0;
  const run = handler(config, async (_url, options) => {
    if (++calls === 1) return Response.json({ id: owner });
    const body = JSON.parse(String(options?.body));
    assert.equal(body.p_user, owner);
    assert.equal(body.p_device, device);
    assert.equal(body.p_action, 'work_updates');
    return Response.json({ messages: [] });
  });
  const response = await run(request({ action: 'work_updates', device_id: device, user_id: device }));
  assert.equal(response.status, 200);
  assert.equal(calls, 2);
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
const connectedConfig = {...config, credentialKey: btoa('k'.repeat(32)), oauthApps:{google:{id:'client',secret:'secret'}}};

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

import { accountCallback, unseal } from '../supabase/functions/assistant/connections.ts';
for (const provider of ['github','supabase','spotify','notion'] as const) {
  test(`${provider} account sign-in binds PKCE, provider, owner and device`, async () => {
    const settings={...connectedConfig,oauthApps:{...connectedConfig.oauthApps,github:{id:'github-client',secret:'github-secret'},supabase:{id:'supabase-client',secret:'supabase-secret'},spotify:{id:'spotify-client'},notion:{id:'notion-client',secret:'notion-secret'}}};
    let intent:any, saved:any, consumed=false, state='';
    const fetcher:typeof fetch=async (url,options) => {
      if (String(url).includes('/rpc/')) {
        const body=JSON.parse(String(options?.body));
        if (body.p_action==='list') return Response.json([]);
        if (body.p_action==='begin') { intent={...body.p_args,id:device,user_id:owner,device_id:device}; return Response.json({intent_id:device}); }
        if (body.p_action==='claim') {
          if (consumed) return Response.json({message:'invalid_request'},{status:400});
          consumed=true; return Response.json(intent);
        }
        if (body.p_action==='complete') { saved=body; return Response.json({}); }
        if (body.p_action==='fail') return Response.json({});
        throw Error('Unexpected action');
      }
      if (String(url).includes('/token') || String(url).endsWith('/access_token')) {
        const form=new URLSearchParams(provider==='notion'?JSON.parse(String(options?.body)):String(options?.body));
        if (provider==='notion') {
          assert.equal(form.get('code_verifier'),null);
          assert.equal(new Headers(options?.headers).get('content-type'),'application/json');
          assert.equal(new Headers(options?.headers).get('authorization'),'Basic '+btoa('notion-client:notion-secret'));
        } else assert.ok(form.get('code_verifier'));
        assert.equal(form.get('redirect_uri'),`https://example.invalid/functions/v1/assistant/${provider}/callback`);
        if (provider==='supabase') assert.equal(new Headers(options?.headers).get('authorization'),'Basic '+btoa('supabase-client:supabase-secret'));
        if(provider==='spotify') { assert.equal(form.get('client_id'),'spotify-client'); assert.equal(form.get('client_secret'),null); assert.equal(new Headers(options?.headers).get('authorization'),null); }
        return Response.json({access_token:'private-access',refresh_token:'private-refresh',expires_in:3600,scope:'user-read-private user-read-playback-state user-modify-playback-state app-remote-control'});
      }
      return Response.json(provider==='github'?{login:'carter'}:[]);
    };
    const start=await connection(settings,owner,{device_id:device,action:'connection_start',args:{provider}},fetcher);
    const url=new URL(start.url);state=url.searchParams.get('state')!;
    assert.equal(url.searchParams.get('code_challenge_method'),provider==='notion'?null:'S256');
    if (provider==='notion') assert.equal(url.searchParams.get('owner'),'user');
    assert.ok(!url.toString().includes('secret'));
    const req=new Request(`https://example.invalid?state=${state}&code=code`);
    assert.match((await accountCallback(req,settings,provider,fetcher)).headers.get('location')!,/connected/);
    assert.equal(saved.p_user,owner);assert.equal(saved.p_device,device);
    assert.ok(!JSON.stringify(saved).includes('private-access'));
    const credential=JSON.parse(await unseal(settings,saved.p_args.ciphertext,`${owner}:${provider}`));
    assert.equal(credential.refresh_token,'private-refresh');
    assert.match((await accountCallback(req,settings,provider,fetcher)).headers.get('location')!,/failed/);
  });
}

test('a provider cannot consume another provider’s authorization code',async()=>{
  let intent:any, providerCalls=0;
  const settings={...connectedConfig,oauthApps:{...connectedConfig.oauthApps,github:{id:'id',secret:'secret'},supabase:{id:'id',secret:'secret'}}};
  const fetcher:typeof fetch=async(url,options)=>{
    if(!String(url).includes('/rpc/')) { providerCalls++;throw Error('Must not contact provider'); }
    const body=JSON.parse(String(options?.body));
    if(body.p_action==='list')return Response.json([]);
    if(body.p_action==='begin'){intent={...body.p_args,id:device,user_id:owner,device_id:device};return Response.json({intent_id:device});}
    if(body.p_action==='claim')return Response.json(intent);
    return Response.json({});
  };
  const start=await connection(settings,owner,{device_id:device,action:'connection_start',args:{provider:'github'}},fetcher);
  const state=new URL(start.url).searchParams.get('state');
  const response=await accountCallback(new Request(`https://example.invalid?state=${state}&code=code`),settings,'supabase',fetcher);
  assert.match(response.headers.get('location')!,/failed/);assert.equal(providerCalls,0);
});


test('connection listing distinguishes saved access from configured sign-in', async () => {
  const result = await connection(connectedConfig, owner, {action:'connections',device_id:device}, async () =>
    Response.json([{slot:'github',metadata:{account:'example'}}]));
  const github = result.providers.find((item:any) => item.id === 'github');
  assert.equal(github.state, 'connected');
  assert.equal(github.configured, false);
  assert.equal(github.kind, 'oauth');
  const notion = result.providers.find((item:any) => item.id === 'notion');
  assert.equal(notion.kind, 'oauth');
  assert.equal(notion.configured, false);
  assert.equal(notion.state, 'absent');
  assert.ok(notion.capabilities.includes('pages.read'));
});

test('missing registrations and token-only services never create an OAuth intent', async () => {
  for (const provider of ['github','supabase','todoist','notion','unregistered']) {
    const actions: string[] = [];
    await assert.rejects(connection(connectedConfig,owner,{action:'connection_start',device_id:device,args:{provider}},async (_url,options) => {
      actions.push(JSON.parse(String(options?.body)).p_action);
      return Response.json([]);
    }));
    assert.deepEqual(actions,['list']);
  }
});

test('retired browser commands are rejected before privileged database access', async () => {
  const fetcher:typeof fetch = async () => { throw new Error('No database request should be made'); };
  const {execute} = await import('../supabase/functions/assistant/handler.ts');
  for (const action of ['browser_list','browser_begin','browser_command']) {
    const response = await execute(config,owner,{action,device_id:device,args:{}},fetcher);
    assert.equal(response.status,400);
  }
});

test('Spotify commands expose only the public app identifier after device validation', async () => {
  const settings={...connectedConfig,oauthApps:{spotify:{id:'public-client'}}};
  const result=await connection(settings,owner,{device_id:device,action:'spotify_command',args:{action:'claim',command_id:device}},async(url,options)=>{
    const input=JSON.parse(String(options?.body));
    assert.equal(input.p_user,owner);assert.equal(input.p_device,device);
    if(String(url).endsWith('assistant_connection_store')) return Response.json([]);
    assert.equal(input.p_action,'claim');
    return Response.json({state:'ready',command:{action:'resume'}});
  });
  assert.deepEqual(result,{state:'ready',command:{action:'resume'},client_id:'public-client'});
  let calls=0;
  await assert.rejects(connection(settings,owner,{device_id:device,action:'spotify_command',args:{action:'claim'}},async()=>{
    calls++;return Response.json({message:'device_denied'},{status:403});
  }),/device_denied/);
  assert.equal(calls,1);
});

test('email approval uses authenticated client identity and a dedicated RPC', async () => {
  let calls = 0;
  const run = handler(config, async (url, options) => {
    if (++calls === 1) return Response.json({id:owner});
    assert.equal(String(url),config.url+'/rest/v1/rpc/assistant_email');
    const input=JSON.parse(String(options?.body));
    assert.equal(input.p_user,owner); assert.equal(input.p_action,'approve');
    assert.equal(input.p_args.version,3);assert.equal(input.p_args.content_hash,'exact-displayed-hash');
    return Response.json({state:'queued'});
  });
  assert.equal((await run(request({action:'email',device_id:device,args:{operation:'approve',id:owner,version:3,content_hash:'exact-displayed-hash'}}))).status,200);
});

test('email RPC rejects caller-supplied dispatch or delivery actions', async () => {
  let calls=0;
  const run=handler(config,async()=>{calls++;return Response.json({id:owner});});
  assert.equal((await run(request({action:'email',device_id:device,args:{operation:'send'}}))).status,400);
  assert.equal(calls,1);
});

test('image reads cannot sign objects before account and device checks pass', async () => {
  let calls=0;
  const run=handler(config,async (url) => {
    if (++calls===1) return Response.json({id:owner});
    assert.equal(String(url),config.url+'/rest/v1/rpc/assistant_image');
    return Response.json({message:'device_denied'},{status:403});
  });
  assert.equal((await run(request({action:'image',device_id:device,args:{operation:'get',id:owner}}))).status,403);
  assert.equal(calls,2);
});

test('image upload rejects a claimed image MIME type with different bytes', async () => {
  let calls=0;
  const run=handler(config,async ()=>{calls++;return Response.json({id:owner});});
  assert.equal((await run(request({action:'image',device_id:device,args:{operation:'upload',id:owner,name:'fake.jpg',mime:'image/jpeg',data:btoa('<html>not a photo</html>')}}))).status,400);
  assert.equal(calls,1);
});
