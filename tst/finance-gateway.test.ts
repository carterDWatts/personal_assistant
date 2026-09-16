import { test } from 'node:test';
import assert from 'node:assert/strict';
import { bankCallback, startBank } from '../supabase/functions/assistant/finance.ts';
import { seal, unseal, hash, connection } from '../supabase/functions/assistant/connections.ts';
const user='aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',device='bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb';
const config={url:'https://example.invalid',serviceKey:'private',anonKey:'public',credentialKey:btoa('x'.repeat(32)),plaid:{id:'client',secret:'private-secret',environment:'sandbox'}};

test('bank tokens reject another owner and ciphertext tampering',async()=>{
  const aad=`${user}:plaid:sandbox:item`;
  const encrypted=await seal(config,'bank-secret',aad);
  assert.equal(await unseal(config,encrypted,aad),'bank-secret');
  await assert.rejects(()=>unseal(config,encrypted,`${device}:plaid:sandbox:item`));
  const bytes=Uint8Array.from(atob(encrypted),c=>c.charCodeAt(0));bytes[bytes.length-1]^=1;
  await assert.rejects(()=>unseal(config,btoa(String.fromCharCode(...bytes)),aad));
});

test('missing callback state never contacts Plaid or the database',async()=>{
  let called=false;
  const result=await bankCallback(new Request('https://example.invalid/plaid/callback'),config,async()=>{
    called=true;throw new Error('unexpected I/O');
  });
  assert.equal(called,false);
  assert.equal(result.headers.get('location'),'personal-assistant://connection?status=failed');
});

test('bank access is checked before external I/O',async()=>{
  const urls:string[]=[];
  await assert.rejects(()=>connection(config,user,{device_id:device,action:'connection_start',args:{provider:'plaid'}},async(url)=>{
    urls.push(String(url));return Response.json({message:'device_denied'},{status:403});
  }));
  assert.equal(urls.length,1);assert.ok(urls[0].includes('/rpc/assistant_connection_store'));
});

for (const healthy of [false,true]) test('bank repair '+(healthy?'keeps the original item':'rejects a still-broken item'),async()=>{
  const state='repair-state',stateHash=await hash(state);
  const repair={id:'existing',environment:'sandbox',institution:'Bank',ciphertext:await seal(config,'existing-token',`${user}:plaid:sandbox:existing`)};
  const verifier=await seal(config,JSON.stringify({link_token:'owned-link',environment:'sandbox',repair}),`oauth:${stateHash}`);
  let completed=false;
  const result=await bankCallback(new Request('https://example.invalid/plaid/callback?state='+state),config,async(url,init)=>{
    const body=JSON.parse(String(init?.body));
    if(String(url).endsWith('assistant_connection_store')){
      if(body.p_action==='claim')return Response.json({id:'intent',slot:'plaid',user_id:user,device_id:device,verifier});
      assert.equal(body.p_action,'fail');return Response.json({});
    }
    if(String(url).endsWith('/link/token/get'))return Response.json({link_sessions:[{on_success:{}}]});
    if(String(url).endsWith('/item/get')){
      assert.equal(body.access_token,'existing-token');
      return Response.json({item:{error:healthy?null:{error_code:'ITEM_LOGIN_REQUIRED'}}});
    }
    assert.ok(String(url).endsWith('assistant_bank_store'));
    completed=true;assert.equal(body.p_args.item_id,'existing');
    assert.equal(await unseal(config,body.p_args.ciphertext,`${user}:plaid:sandbox:existing`),'existing-token');
    return Response.json({});
  });
  assert.equal(completed,healthy);
  assert.equal(result.headers.get('location'),'personal-assistant://connection?status='+(healthy?'connected':'failed'));
});

test('bank sign-in requests read products and stores an encrypted owned link',async()=>{
  const result=await startBank(config,user,device,async(url,init)=>{
    const body=JSON.parse(String(init?.body));
    if(String(url).includes('plaid.com')){
      assert.deepEqual(body.products,['transactions']);assert.deepEqual(body.optional_products,['liabilities']);
      assert.equal(body.user.client_user_id,user);assert.equal(body.hosted_link.is_mobile_app,true);
      assert.equal(body.redirect_uri,'https://secure.plaid.com/oauth/redirect');
      return Response.json({link_token:'owned-secret-link',hosted_link_url:'https://secure.plaid.com/hl/test'});
    }
    if(body.p_action==='repair')return Response.json(null);
    assert.equal(body.p_user,user);assert.equal(body.p_device,device);assert.equal(body.p_args.slot,'plaid');
    assert.ok(!body.p_args.verifier.includes('owned-secret-link'));
    return Response.json({intent_id:'intent'});
  });
  assert.deepEqual(result,{intent_id:'intent',url:'https://secure.plaid.com/hl/test'});
});

for(const success of [false,true]) test('callback '+(success?'uses the owned session token':'does not trust a browser claim of success'),async()=>{
  let completed=false,exchanged=false;
  const state='test-state';const stateHash=await hash(state);
  const verifier=await seal(config,JSON.stringify({link_token:'owned-link',environment:'sandbox'}),`oauth:${stateHash}`);
  const result=await bankCallback(new Request('https://example.invalid/plaid/callback?state='+state+'&public_token=attacker'),config,async(url,init)=>{
    const body=JSON.parse(String(init?.body));
    if(String(url).endsWith('assistant_connection_store')){
      if(body.p_action==='claim')return Response.json({id:'intent',slot:'plaid',user_id:user,device_id:device,verifier});
      assert.equal(body.p_action,'fail');return Response.json({});
    }
    if(String(url).endsWith('/link/token/get')){
      assert.equal(body.link_token,'owned-link');
      return Response.json({link_sessions:success?[{results:{item_add_results:[{public_token:'verified',institution:{name:'Test bank'}}]}}]:[]});
    }
    if(String(url).endsWith('/item/public_token/exchange')){
      exchanged=true;assert.equal(body.public_token,'verified');return Response.json({item_id:'item',access_token:'secret-token'});
    }
    assert.ok(String(url).endsWith('assistant_bank_store'));completed=true;
    assert.equal(body.p_user,user);assert.equal(body.p_device,device);assert.equal(body.p_args.item_id,'item');
    assert.ok(!body.p_args.ciphertext.includes('secret-token'));return Response.json({});
  });
  assert.equal(completed,success);assert.equal(exchanged,success);
  assert.equal(result.headers.get('location'),'personal-assistant://connection?status='+(success?'connected':'failed'));
});
