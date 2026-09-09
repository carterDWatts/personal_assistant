import asyncio
import base64
import json
import os
import tempfile
import uuid
from unittest.mock import patch
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.hazmat.primitives import serialization
from engine.browser.crypto import seal,unseal
from engine.browser.client import origin
from engine.tools import ToolError
from engine.db import jsonb
from tst.helpers import MapTest

class browser_test(MapTest):
    def setUp(self):
        super().setUp()
        self.map.execute('truncate assistant.browser_sessions cascade')
        self.map.execute('truncate assistant.owner cascade')
        self.owner=uuid.uuid4();self.device=uuid.uuid4()
        self.map.execute('insert into assistant.owner(user_id) values(%s)',(self.owner,))
        self.map.execute("insert into assistant.devices(id,user_id,name) values(%s,%s,'browser test')",(self.device,self.owner))
        self.session=self.map.value("insert into assistant.browser_sessions(user_id,origin,url,requested_for) values(%s,'https://workbench.example','https://workbench.example','Finish the task') returning id",(self.owner,))

    def test_access_is_scoped_and_requires_human_takeover(self):
        with self.assertRaises(Exception):
            self.map.value('select public.assistant_browser(%s,%s,%s,%s)',(uuid.uuid4(),self.device,'browser_list',jsonb({})))
        with self.assertRaises(Exception):
            self.map.value('select public.assistant_browser(%s,%s,%s,%s)',(self.owner,self.device,'browser_command',jsonb({'session_id':str(self.session),'id':str(uuid.uuid4()),'encrypted':'opaque'})))
        self.assertEqual(self.map.value('select count(*) from assistant.browser_commands'),0)

    def test_takeover_waits_for_running_action(self):
        self.map.execute("insert into assistant.browser_host(singleton,public_key) values(true,'test') on conflict(singleton) do update set seen_at=now()")
        self.map.execute("update assistant.browser_sessions set state='ready' where id=%s",(self.session,))
        self.map.execute("insert into assistant.browser_commands(id,session_id,actor,encrypted,status) values(%s,%s,'agent','opaque','running')",(uuid.uuid4(),self.session))
        for action in ('browser_begin','browser_disconnect'):
            with self.assertRaises(Exception):
                self.map.value('select public.assistant_browser(%s,%s,%s,%s)',(self.owner,self.device,action,jsonb({'session_id':str(self.session)})))
        self.assertEqual(self.map.value('select state from assistant.browser_sessions where id=%s',(self.session,)),'ready')

    def test_command_encryption_is_bound_to_request(self):
        private=rsa.generate_private_key(public_exponent=65537,key_size=2048)
        public=private.public_key().public_bytes(serialization.Encoding.PEM,serialization.PublicFormat.SubjectPublicKeyInfo).decode()
        envelope=seal(public,{'text':'secret test input'},'one')
        self.assertNotIn('secret test input',envelope)
        self.assertEqual(unseal(private,envelope,'one'),{'text':'secret test input'})
        with self.assertRaises(Exception):unseal(private,envelope,'two')
        for url in ('http://example.com','https://name:password@example.com','file:///etc/passwd','https://example.com:22'):
            with self.assertRaises(ToolError):origin(url)

    def test_real_browser_login_handoff_action_and_storage_reuse(self):
        from engine.browser.worker import Worker
        with tempfile.TemporaryDirectory() as temp,patch.dict(os.environ,{'ASSISTANT_BROWSER_KEY_FILE':temp+'/key.pem','ASSISTANT_CREDENTIAL_KEY':base64.b64encode(b'a'*32).decode()}):
            async def scenario():
                worker=Worker(self.map);await worker.start()
                complete=False
                async def fixture(route):
                    nonlocal complete
                    url=route.request.url
                    if url.endswith('/login'):
                        await route.fulfill(status=200,headers={'Set-Cookie':'access=yes; Path=/; Secure; HttpOnly'},body='Signed in');return
                    if url.endswith('/complete'):
                        complete=True;await route.fulfill(body='done');return
                    signed='access=yes' in route.request.headers.get('cookie','')
                    html=('<button onclick="fetch(\'/complete\',{method:\'POST\'}).then(()=>document.body.innerText=\'Task completed\')">Finish task</button>' if signed else '<input aria-label="Password" type="password"><button onclick="fetch(\'/login\',{method:\'POST\'}).then(()=>location.reload())">Sign in</button>')
                    await route.fulfill(content_type='text/html',body=html)
                async def context(storage=None):
                    c=await worker.browser.new_context(viewport={'width':1024,'height':768},storage_state=storage)
                    await c.route('**/*',fixture)
                    p=await c.new_page();await p.goto('https://workbench.example');worker.contexts[str(self.session)]=c
                    worker.last_used[str(self.session)]=__import__("time").monotonic()
                    return p
                async def cmd(actor,payload):
                    identifier=uuid.uuid4()
                    self.map.execute('insert into assistant.browser_commands(id,session_id,actor,encrypted) values(%s,%s,%s,%s)',(identifier,self.session,actor,seal(worker.public,payload,identifier)))
                    await worker.tick()
                    return self.map.row('select status,result,encrypted from assistant.browser_commands where id=%s',(identifier,))
                try:
                    p=await context()
                    blocked=await cmd('agent',{'action':'snapshot'})
                    self.assertEqual(blocked['status'],'failed')
                    self.map.value('select public.assistant_browser(%s,%s,%s,%s)',(self.owner,self.device,'browser_begin',jsonb({'session_id':str(self.session)})))
                    shot=await cmd('human',{'action':'snapshot'})
                    self.assertIn('image',shot['result']);self.assertEqual(shot['encrypted'],'')
                    box=await p.get_by_label('Password').bounding_box()
                    await cmd('human',{'action':'tap','x':box['x']+10,'y':box['y']+10})
                    await cmd('human',{'action':'type','text':'test-password'})
                    self.assertEqual(await p.get_by_label('Password').input_value(),'test-password')
                    box=await p.get_by_role('button',name='Sign in').bounding_box()
                    await cmd('human',{'action':'tap','x':box['x']+5,'y':box['y']+5})
                    await p.get_by_role('button',name='Finish task').wait_for()
                    result=await cmd('human',{'action':'finish'})
                    self.assertTrue(result['result']['ready'])
                    stored=self.map.row('select * from assistant.browser_sessions where id=%s',(self.session,))
                    self.assertNotIn('access',stored['storage'])
                    await worker.contexts.pop(str(self.session)).close()
                    p=await context(worker.storage(stored))
                    snap=(await cmd('agent',{'action':'snapshot'}))['result']
                    self.assertNotIn('image',snap)
                    button=next(e for e in snap['elements'] if e['label']=='Finish task')
                    outcome=await cmd('agent',{'action':'click','element':button['id'],'revision':snap['revision']})
                    self.assertEqual(outcome['status'],'done');self.assertTrue(complete)
                    self.assertIn('Task completed',outcome['result']['text'])
                    self.map.value('select public.assistant_browser(%s,%s,%s,%s)',(self.owner,self.device,'browser_disconnect',jsonb({'session_id':str(self.session)})))
                    self.assertIsNone(self.map.value('select storage from assistant.browser_sessions where id=%s',(self.session,)))
                    self.assertEqual((await cmd('agent',{'action':'snapshot'}))['status'],'failed')
                finally:await worker.close()
            self.run_async(scenario())
