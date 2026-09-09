import type { Config } from './handler.ts';

export async function imageRequest(config: Config, user: string, input: any, fetcher: typeof fetch = fetch) {
  const args=input.args || {};
  const headers={'Content-Type':'application/json',apikey:config.serviceKey,Authorization:`Bearer ${config.serviceKey}`};
  async function rpc(action: string, fields: any) {
    const response=await fetcher(`${config.url}/rest/v1/rpc/assistant_image`,{method:'POST',headers,
      body:JSON.stringify({p_user:user,p_device:input.device_id,p_action:action,p_args:fields}),signal:AbortSignal.timeout(15000)});
    const value=await response.json();
    if (!response.ok) throw new Error(['account_denied','device_denied'].includes(value.message)?value.message:'invalid_request');
    return value;
  }
  if (args.operation==='get') {
    const row=await rpc('get',{id:args.id});
    const result=await fetcher(`${config.url}/storage/v1/object/sign/chat-images/${row.path}`,{method:'POST',headers,body:JSON.stringify({expiresIn:600}),signal:AbortSignal.timeout(15000)});
    if (!result.ok) throw new Error('service_unavailable');
    return {...row,url:config.url+'/storage/v1'+(await result.json()).signedURL};
  }
  if (args.operation!=='upload' || typeof args.data!=='string' || args.data.length>5333336 || !['image/jpeg','image/png','image/webp'].includes(args.mime)) throw new Error('invalid_request');
  let bytes: Uint8Array;
  try { bytes=Uint8Array.from(atob(args.data),c=>c.charCodeAt(0)); } catch { throw new Error('invalid_request'); }
  if (bytes.length<12 || bytes.length>4000000) throw new Error('invalid_request');
  const magic=args.mime==='image/jpeg' ? bytes[0]===255&&bytes[1]===216&&bytes[2]===255 : args.mime==='image/png'
    ? bytes.slice(0,8).join(',')==='137,80,78,71,13,10,26,10'
    : new TextDecoder().decode(bytes.slice(0,4))==='RIFF'&&new TextDecoder().decode(bytes.slice(8,12))==='WEBP';
  if (!magic) throw new Error('invalid_request');
  const sha256=Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256',bytes))).map(x=>x.toString(16).padStart(2,'0')).join('');
  let row=await rpc('reserve',{id:args.id,name:args.name,mime:args.mime,bytes:bytes.length,sha256});
  if (!row.ready) {
    const response=await fetcher(`${config.url}/storage/v1/object/chat-images/${row.path}`,{method:'POST',headers:{...headers,'Content-Type':args.mime,'x-upsert':'true'},body:bytes,signal:AbortSignal.timeout(20000)});
    if (!response.ok) throw new Error('service_unavailable');
    row=await rpc('complete',{id:row.id});
  }
  return {id:row.id,name:row.name,mime:row.mime};
}
