import type { Config } from './handler.ts';

const scope = 'https://www.googleapis.com/auth/';
const grants: Record<string, {slot: string; scopes: string[]}> = {
  calendar: {slot: 'google_connect', scopes: [scope+'calendar.readonly', scope+'gmail.readonly']},
  calendar_write: {slot: 'google_connect', scopes: [scope+'calendar.readonly', scope+'gmail.readonly', scope+'calendar.events', scope+'calendar.calendars']},
  tasks: {slot: 'google_tasks', scopes: [scope+'tasks.readonly']},
  drive: {slot: 'google_drive', scopes: [scope+'drive.readonly']},
  contacts: {slot: 'google_contacts', scopes: [scope+'contacts.readonly']},
};
const providers: Record<string, {url: string; headers?: Record<string,string>}> = {
  todoist: {url: 'https://api.todoist.com/api/v1/projects?limit=1'},
  notion: {url: 'https://api.notion.com/v1/users/me', headers: {'Notion-Version': '2026-03-11'}},
  supabase: {url: 'https://api.supabase.com/v1/organizations'},
  github: {url: 'https://api.github.com/user', headers: {'X-GitHub-Api-Version': '2022-11-28', 'User-Agent':'personal-assistant'}},
};
export const connectionActions = new Set(['connections','connection_start','connection_status','connection_token','connection_remove']);
const encode = new TextEncoder();
const b64 = (v: Uint8Array) => btoa(String.fromCharCode(...v));
const bytes = (v: string) => Uint8Array.from(atob(v), x => x.charCodeAt(0));
const random = () => b64(crypto.getRandomValues(new Uint8Array(32))).replaceAll('+','-').replaceAll('/','_').replaceAll('=','');
const hash = async (v: string) => b64(new Uint8Array(await crypto.subtle.digest('SHA-256',encode.encode(v)))).replaceAll('+','-').replaceAll('/','_').replaceAll('=','');
async function key(config: Config) {
  if (!config.credentialKey) throw new Error('connections_unavailable');
  return crypto.subtle.importKey('raw',bytes(config.credentialKey), 'AES-GCM',false,['encrypt','decrypt']);
}
export async function seal(config: Config, value: string, aad: string) {
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const encrypted = new Uint8Array(await crypto.subtle.encrypt({name:'AES-GCM',iv,additionalData:encode.encode(aad)}, await key(config),encode.encode(value)));
  return b64(new Uint8Array([...iv,...encrypted]));
}
export async function unseal(config: Config, value: string, aad: string) {
  const data = bytes(value);
  return new TextDecoder().decode(await crypto.subtle.decrypt({name:'AES-GCM',iv:data.slice(0,12),additionalData:encode.encode(aad)},await key(config),data.slice(12)));
}
async function store(config: Config, user: string | null, device: string | null, action: string, args: object, fetcher: typeof fetch) {
  const response = await fetcher(`${config.url}/rest/v1/rpc/assistant_connection_store`, {
    method:'POST', headers:{'Content-Type':'application/json',apikey:config.serviceKey,authorization:`Bearer ${config.serviceKey}`},
    body:JSON.stringify({p_user:user,p_device:device,p_action:action,p_args:args}),signal:AbortSignal.timeout(15000),
  });
  const result = await response.json();
  if (!response.ok) throw new Error(['account_denied','device_denied'].includes(result.message) ? result.message : 'invalid_request');
  return result;
}
const callbackURL = (config: Config) => `${config.url}/functions/v1/assistant/google/callback`;
function slot(provider: string, grant: string) {
  if (provider === 'google' && Object.hasOwn(grants,grant)) return grants[grant].slot;
  if (Object.hasOwn(providers,provider)) return provider;
  throw new Error('invalid_request');
}

export async function connection(config: Config, user: string, input: any, fetcher: typeof fetch) {
  // Every operation validates the authenticated owner and device before external I/O.
  const rows = await store(config,user,input.device_id,'list',{},fetcher) as any[];
  const args = input.args || {}, provider = args.provider;
  if (input.action === 'connections') {
    const google = rows.filter(r => r.slot.startsWith('google_'));
    const linked = Object.entries(grants).filter(([,g]) => google.some(r => r.slot===g.slot && g.scopes.every(s => (r.metadata.scopes || []).includes(s)))).map(([name])=>name);
    return {providers:[{id:'google',kind:'google',state:google.length?'connected':'absent',grants:linked,account:google[0]?.metadata.account || null},
      ...Object.keys(providers).map(id=>({id,kind:['github','supabase'].includes(id)?'oauth':'token',state:rows.some(r=>r.slot===id)?'connected':'absent',account:rows.find(r=>r.slot===id)?.metadata.account || null}))]};
  }
  if (input.action === 'connection_status') return store(config,user,input.device_id,'status',{intent_id:args.intent_id},fetcher);
  const grant = args.grant || 'calendar', name = slot(provider,grant);
  if (input.action === 'connection_remove') return store(config,user,input.device_id,'remove',{slot:name},fetcher);
  if (input.action === 'connection_start') {
    if (provider === 'github' || provider === 'supabase') return startAccount(config,user,input.device_id,provider,fetcher);
    if (provider !== 'google' || !config.googleClientId || !config.googleClientSecret) throw new Error('connections_unavailable');
    const state = random(), verifier = random();
    const stateHash = await hash(state);
    const intent = await store(config,user,input.device_id,'begin',{slot:name,state_hash:stateHash,
      verifier:await seal(config,JSON.stringify({verifier,scopes:grants[grant].scopes}),`oauth:${stateHash}`)},fetcher);
    const url = new URL('https://accounts.google.com/o/oauth2/v2/auth');
    url.search = new URLSearchParams({client_id:config.googleClientId,redirect_uri:callbackURL(config),response_type:'code',
      scope:['openid','email',...grants[grant].scopes].join(' '),access_type:'offline',prompt:'consent',
      state,code_challenge:await hash(verifier),code_challenge_method:'S256'}).toString();
    return {...intent,url:url.toString()};
  }
  if (input.action === 'connection_token') {
    if (!Object.hasOwn(providers,provider) || typeof args.token !== 'string' || !args.token.trim() || args.token.length>8192) throw new Error('invalid_request');
    const token = args.token.trim(), details=providers[provider];
    const result = await fetcher(details.url,{headers:{Authorization:`Bearer ${token}`, ...details.headers},redirect:'error',signal:AbortSignal.timeout(10000)});
    if (!result.ok) throw new Error('connection_rejected');
    const data = await result.json();
    const account = String(data.login || data.name || provider).slice(0,200);
    await store(config,user,input.device_id,'save',{slot:name,ciphertext:await seal(config,token,`${user}:${name}`),metadata:{account}},fetcher);
    return {account};
  }
  throw new Error('invalid_request');
}

export async function googleCallback(req: Request, config: Config, fetcher: typeof fetch = fetch) {
  let intent: any;
  try {
    const url = new URL(req.url), state = url.searchParams.get('state');
    if (!state || state.length>128) throw new Error('invalid_request');
    const stateHash = await hash(state);
    intent = await store(config,null,null,'claim',{state_hash:stateHash},fetcher);
    if (url.searchParams.has('error')) throw new Error('connection_rejected');
    const code = url.searchParams.get('code');
    if (!code || code.length>8192 || !config.googleClientId || !config.googleClientSecret) throw new Error('invalid_request');
    const auth = JSON.parse(await unseal(config,intent.verifier,`oauth:${stateHash}`));
    const result = await fetcher('https://oauth2.googleapis.com/token',{method:'POST',
      body:new URLSearchParams({code,client_id:config.googleClientId,client_secret:config.googleClientSecret,
        redirect_uri:callbackURL(config),grant_type:'authorization_code',code_verifier:auth.verifier}),signal:AbortSignal.timeout(15000)});
    if (!result.ok) throw new Error('connection_rejected');
    const token = await result.json(), scopes = (token.scope || '').split(' ');
    if (!token.refresh_token || !token.access_token || !auth.scopes.every((s:string)=>scopes.includes(s))) throw new Error('connection_rejected');
    const profile = await fetcher('https://openidconnect.googleapis.com/v1/userinfo', {headers:{Authorization:`Bearer ${token.access_token}`},signal:AbortSignal.timeout(10000)});
    if (!profile.ok) throw new Error('connection_rejected');
    const account = (await profile.json()).email;
    const credential = JSON.stringify({token:token.access_token,refresh_token:token.refresh_token,token_uri:'https://oauth2.googleapis.com/token',
      client_id:config.googleClientId,client_secret:config.googleClientSecret,scopes,expiry:new Date(Date.now()+token.expires_in*1000).toISOString()});
    await store(config,intent.user_id,intent.device_id,'complete',{intent_id:intent.id,
      ciphertext:await seal(config,credential,`${intent.user_id}:${intent.slot}`),metadata:{account,scopes}},fetcher);
    return Response.redirect('personal-assistant://connection?status=connected',302);
  } catch {
    if (intent) { try { await store(config,intent.user_id,intent.device_id,'fail',{intent_id:intent.id},fetcher); } catch {} }
    return Response.redirect('personal-assistant://connection?status=failed',302);
  }
}


type AccountProvider = 'github' | 'supabase';
function accountConfig(config: Config, provider: AccountProvider) {
  const details = provider === 'github'
    ? {id:config.githubClientId, secret:config.githubClientSecret, authorize:'https://github.com/login/oauth/authorize', token:'https://github.com/login/oauth/access_token'}
    : {id:config.supabaseClientId, secret:config.supabaseClientSecret, authorize:'https://api.supabase.com/v1/oauth/authorize', token:'https://api.supabase.com/v1/oauth/token'};
  if (!details.id || !details.secret) throw new Error('connections_unavailable');
  return {...details, id:details.id, secret:details.secret};
}
const accountCallbackURL = (config: Config, provider: AccountProvider) => `${config.url}/functions/v1/assistant/${provider}/callback`;
async function startAccount(config: Config, user: string, device: string, provider: AccountProvider, fetcher: typeof fetch) {
  const details=accountConfig(config,provider), state=random(), verifier=random(), stateHash=await hash(state);
  const intent=await store(config,user,device,'begin',{slot:provider,state_hash:stateHash,
    verifier:await seal(config,JSON.stringify({provider,verifier}),`oauth:${stateHash}`)},fetcher);
  const url=new URL(details.authorize);
  url.search=new URLSearchParams({client_id:details.id,redirect_uri:accountCallbackURL(config,provider),response_type:'code',
    state,code_challenge:await hash(verifier),code_challenge_method:'S256',
    ...(provider==='github'?{scope:'read:user repo'}:{})}).toString();
  return {...intent,url:url.toString()};
}

export async function accountCallback(req: Request, config: Config, provider: AccountProvider, fetcher: typeof fetch=fetch) {
  let intent: any;
  try {
    const url=new URL(req.url), state=url.searchParams.get('state');
    if (!state || state.length>128) throw new Error('invalid_request');
    const stateHash=await hash(state);
    intent=await store(config,null,null,'claim',{state_hash:stateHash},fetcher);
    const auth=JSON.parse(await unseal(config,intent.verifier,`oauth:${stateHash}`));
    if (intent.slot!==provider || auth.provider!==provider || url.searchParams.has('error')) throw new Error('connection_rejected');
    const code=url.searchParams.get('code'), details=accountConfig(config,provider);
    if (!code || code.length>8192) throw new Error('invalid_request');
    const body=new URLSearchParams({grant_type:'authorization_code',code,redirect_uri:accountCallbackURL(config,provider),code_verifier:auth.verifier});
    const headers: Record<string,string>={'Accept':'application/json','Content-Type':'application/x-www-form-urlencoded'};
    if (provider==='supabase') headers.Authorization='Basic '+btoa(details.id+':'+details.secret);
    else { body.set('client_id',details.id); body.set('client_secret',details.secret); }
    const response=await fetcher(details.token,{method:'POST',headers,body,redirect:'error',signal:AbortSignal.timeout(15000)});
    if (!response.ok) throw new Error('connection_rejected');
    const token=await response.json();
    if (!token.access_token || token.error || (provider==='supabase' && !token.refresh_token)) throw new Error('connection_rejected');
    const profile=await fetcher(providers[provider].url,{headers:{Authorization:'Bearer '+token.access_token,...providers[provider].headers},redirect:'error',signal:AbortSignal.timeout(10000)});
    if (!profile.ok) throw new Error('connection_rejected');
    const info=await profile.json();
    const account=provider==='github'?String(info.login):'Supabase account';
    const credential=JSON.stringify({token:token.access_token,refresh_token:token.refresh_token,token_uri:details.token,
      client_id:details.id,client_secret:details.secret,provider,
      expiry:token.expires_in?new Date(Date.now()+token.expires_in*1000).toISOString():null});
    await store(config,intent.user_id,intent.device_id,'complete',{intent_id:intent.id,
      ciphertext:await seal(config,credential,`${intent.user_id}:${intent.slot}`),metadata:{account,kind:'oauth'}},fetcher);
    return Response.redirect('personal-assistant://connection?status=connected',302);
  } catch {
    if (intent) { try { await store(config,intent.user_id,intent.device_id,'fail',{intent_id:intent.id},fetcher); } catch {} }
    return Response.redirect('personal-assistant://connection?status=failed',302);
  }
}
