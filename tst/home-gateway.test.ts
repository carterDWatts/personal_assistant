import { test } from 'node:test';
import assert from 'node:assert/strict';
import { imageRequest } from '../supabase/functions/assistant/images.ts';
import { startBank } from '../supabase/functions/assistant/finance.ts';
import { connection } from '../supabase/functions/assistant/connections.ts';

const config = {url:'http://api:8000', publicUrl:'https://home.example:10000/',
  anonKey:'public', serviceKey:'private', credentialKey:btoa('x'.repeat(32)),
  plaid:{id:'client', secret:'secret', environment:'sandbox'},
  oauthApps:{google:{id:'google-id',secret:'google-secret'}}};

test('private image I/O stays internal while the phone receives a public URL', async () => {
  const urls: string[] = [];
  const result = await imageRequest(config,'owner',{device_id:'phone',args:{operation:'get',id:'image'}},async url=>{
    urls.push(String(url));
    return Response.json(urls.length===1 ? {path:'owner/image.jpg'} : {signedURL:'/object/sign/chat-images/image?token=signed'});
  });
  assert.ok(urls.every(url=>url.startsWith('http://api:8000/')));
  assert.equal(result.url,'https://home.example:10000/storage/v1/object/sign/chat-images/image?token=signed');
});

test('Google uses a public callback and internal credential storage', async () => {
  let calls=0;
  const result=await connection(config,'owner',{device_id:'phone',action:'connection_start',args:{provider:'google',grant:'calendar'}},async url=>{
    assert.ok(String(url).startsWith(config.url));
    return Response.json(++calls===1 ? [] : {intent_id:'intent'});
  });
  assert.equal(new URL(result.url).searchParams.get('redirect_uri'),'https://home.example:10000/functions/v1/assistant/google/callback');
});

test('bank callback never points to the Docker network', async () => {
  await startBank(config,'owner','phone',async (url,init)=>{
    const body=JSON.parse(String(init?.body));
    if(String(url).includes('plaid.com')) {
      assert.ok(body.hosted_link.completion_redirect_uri.startsWith('https://home.example:10000/functions/v1/assistant/plaid/callback?state='));
      return Response.json({link_token:'link',hosted_link_url:'https://secure.plaid.com/link'});
    }
    assert.ok(String(url).startsWith(config.url));
    return Response.json(body.p_action==='repair' ? null : {intent_id:'intent'});
  });
});
