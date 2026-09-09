import type { Config } from './handler.ts';
const actions=new Set(['browser_list','browser_begin','browser_command','browser_result','browser_disconnect']);
export const browserActions=actions;
const encode=new TextEncoder();
const b64=(v:Uint8Array)=>btoa(String.fromCharCode(...v));
export async function browser(config:Config,user:string,input:any,fetcher:typeof fetch){
 const rpc=async(action:string,args:any)=>{
  const response=await fetcher(config.url+'/rest/v1/rpc/assistant_browser',{method:'POST',headers:{'Content-Type':'application/json',apikey:config.serviceKey,authorization:'Bearer '+config.serviceKey},body:JSON.stringify({p_user:user,p_device:input.device_id,p_action:action,p_args:args}),signal:AbortSignal.timeout(15000)});
  const value=await response.json();
  if(!response.ok)throw new Error(['account_denied','device_denied'].includes(value.message)?value.message:'browser_unavailable');
  return value;
 };
 const args={...input.args};
 if(input.action==='browser_command'){
  // Validate ownership before processing private keyboard input. Never return or log it.
  const sessions=await rpc('browser_list',{});
  if(!sessions.sessions.some((s:any)=>s.id===args.session_id&&s.state==='human'))throw new Error('invalid_request');
  if(!args.command||typeof args.command!=='object'||JSON.stringify(args.command).length>10000)throw new Error('invalid_request');
  const publicKey=(await rpc('browser_begin',{session_id:args.session_id})).public_key as string;
  const pem=publicKey!.replace(/-----[^-]+-----/g,'').replace(/\s/g,'');
  const publicCrypto=await crypto.subtle.importKey('spki',Uint8Array.from(atob(pem),c=>c.charCodeAt(0)),{name:'RSA-OAEP',hash:'SHA-256'},false,['encrypt']);
  const key=crypto.getRandomValues(new Uint8Array(32)),iv=crypto.getRandomValues(new Uint8Array(12));
  const aes=await crypto.subtle.importKey('raw',key,'AES-GCM',false,['encrypt']);
  const data=await crypto.subtle.encrypt({name:'AES-GCM',iv,additionalData:encode.encode(args.id)},aes,encode.encode(JSON.stringify(args.command)));
  const encrypted=JSON.stringify({key:b64(new Uint8Array(await crypto.subtle.encrypt('RSA-OAEP',publicCrypto,key))),iv:b64(iv),data:b64(new Uint8Array(data))});
  return rpc(input.action,{session_id:args.session_id,id:args.id,encrypted});
 }
 return rpc(input.action,args);
}
