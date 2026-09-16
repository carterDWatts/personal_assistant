import type { Config } from './handler.ts';
import { hash, random, seal, unseal, store } from './connections.ts';

async function plaid(config: Config, path: string, args: object, fetcher: typeof fetch) {
  const client=config.plaid;
  if (!client?.id || !client.secret || !['sandbox','production'].includes(client.environment)) throw new Error('connections_unavailable');
  const response=await fetcher(`https://${client.environment}.plaid.com${path}`, {method:'POST',
    headers:{'Content-Type':'application/json','Plaid-Version':'2020-09-14'},
    body:JSON.stringify({client_id:client.id,secret:client.secret,...args}),
    redirect:'error',signal:AbortSignal.timeout(15000)});
  if (!response.ok) throw new Error('connection_rejected');
  return response.json();
}
export async function bankStore(config: Config, user: string, device: string, action: string, args: object, fetcher: typeof fetch) {
  const response=await fetcher(`${config.url}/rest/v1/rpc/assistant_bank_store`,{method:'POST',
    headers:{'Content-Type':'application/json',apikey:config.serviceKey,authorization:`Bearer ${config.serviceKey}`},
    body:JSON.stringify({p_user:user,p_device:device,p_action:action,p_args:args}),signal:AbortSignal.timeout(15000)});
  if (!response.ok) throw new Error('invalid_request');
  return response.json();
}
export function removeBank(config: Config, user: string, device: string, fetcher: typeof fetch) {
  // Immediately remove access; the worker durably retries provider revocation.
  return bankStore(config,user,device,'remove',{},fetcher);
}
export async function startBank(config: Config, user: string, device: string, fetcher: typeof fetch) {
  const state=random(), stateHash=await hash(state);
  const repair=await bankStore(config,user,device,'repair',{},fetcher);
  if (repair && repair.environment!==config.plaid?.environment) throw new Error('connections_unavailable');
  const access=repair ? await unseal(config,repair.ciphertext,`${user}:plaid:${repair.environment}:${repair.id}`) : null;
  const linked=await plaid(config,'/link/token/create',{
    client_name:config.identity?.name || 'Personal Assistant',user:{client_user_id:user},
    redirect_uri:'https://secure.plaid.com/oauth/redirect',
    language:'en',country_codes:['US'],...(access?{access_token:access}:{products:['transactions'],optional_products:['liabilities']}),
    hosted_link:{is_mobile_app:true,url_lifetime_seconds:600,
      completion_redirect_uri:`${config.url}/functions/v1/assistant/plaid/callback?state=${state}`},
  },fetcher);
  if (!linked.link_token || !linked.hosted_link_url) throw new Error('connection_rejected');
  const intent=await store(config,user,device,'begin',{slot:'plaid',state_hash:stateHash,
    verifier:await seal(config,JSON.stringify({link_token:linked.link_token,environment:config.plaid!.environment,repair}),`oauth:${stateHash}`)},fetcher);
  return {...intent,url:linked.hosted_link_url};
}
export async function bankCallback(req: Request, config: Config, fetcher: typeof fetch=fetch) {
  let intent: any;
  try {
    const state=new URL(req.url).searchParams.get('state');
    if (!state || state.length>128) throw new Error('invalid_request');
    const stateHash=await hash(state);
    intent=await store(config,null,null,'claim',{state_hash:stateHash},fetcher);
    if (intent.slot!=='plaid') throw new Error('invalid_request');
    const link=JSON.parse(await unseal(config,intent.verifier,`oauth:${stateHash}`));
    if (link.environment!==config.plaid?.environment) throw new Error('invalid_request');
    const result=await plaid(config,'/link/token/get',{link_token:link.link_token},fetcher);
    // A browser redirect is not success. Only the owned Link session supplies a token.
    const added=result.link_sessions?.flatMap((session: any)=>session.results?.item_add_results || []) || [];
    const item=added.find((entry: any)=>typeof entry.public_token==='string');
    let token;
    if (link.repair) {
      if (!result.link_sessions?.some((session: any)=>session.on_success)) throw new Error('connection_rejected');
      const access=await unseal(config,link.repair.ciphertext,`${intent.user_id}:plaid:${link.environment}:${link.repair.id}`);
      const status=await plaid(config,'/item/get',{access_token:access},fetcher);
      if (status.item?.error) throw new Error('connection_rejected');
      token={item_id:link.repair.id,access_token:access};
    } else {
      if (!item) throw new Error('connection_rejected');
      token=await plaid(config,'/item/public_token/exchange',{public_token:item.public_token},fetcher);
    }
    if (!token.item_id || !token.access_token) throw new Error('connection_rejected');
    await bankStore(config,intent.user_id,intent.device_id,'complete',{
      intent_id:intent.id,item_id:token.item_id,environment:link.environment,
      institution:link.repair?.institution || item?.metadata?.institution?.name || item?.institution?.name || 'Bank',
      ciphertext:await seal(config,token.access_token,`${intent.user_id}:plaid:${link.environment}:${token.item_id}`),
    },fetcher);
    if (link.desktop) return new Response('Bank connected. You can return to Bunny Man.',{headers:{'Content-Type':'text/plain','Cache-Control':'no-store'}});
    return Response.redirect('personal-assistant://connection?status=connected',302);
  } catch {
    if (intent) { try { await store(config,intent.user_id,intent.device_id,'fail',{intent_id:intent.id},fetcher); } catch {} }
    return Response.redirect('personal-assistant://connection?status=failed',302);
  }
}
