import uuid
from unittest.mock import patch
import psycopg
from engine.db import jsonb
from engine.tools import Tools, ToolError
from engine.integrations.email import Drafts, addresses, dispatch, deliver
from tst.helpers import MapTest


class email_test(MapTest):
    def setUp(self):
        super().setUp()
        self.map.execute('truncate assistant.owner,assistant.host cascade')
        self.owner,self.device=uuid.uuid4(),uuid.uuid4()
        self.map.execute('insert into assistant.owner(user_id) values(%s)',(self.owner,))
        self.map.value('select public.assistant_client(%s,%s,%s,%s)',(self.owner,self.device,'register',jsonb({'name':'Test phone'})))
        self.tools=Tools(self.map,'cloud');self.drafts=Drafts(self.tools)
        self.args={'to':['recipient@example.com'],'subject':'A draft','body':'Please check this.'}

    def tearDown(self):
        if getattr(self,'map',None): self.map.execute('truncate assistant.owner,assistant.host cascade')
        super().tearDown()

    def draft(self,**kwargs):
        with patch('engine.integrations.email.mailbox',return_value='owner@example.com'):
            return self.run_async(self.drafts.prepare({**self.args,**kwargs}))['draft']

    def approve(self,draft,**kwargs):
        return self.map.value('select public.assistant_email(%s,%s,%s,%s)',
            (self.owner,self.device,'approve',jsonb({'id':str(draft['id']),'version':draft['version'],'content_hash':draft['content_hash'],**kwargs})))

    def test_only_exact_reviewed_version_can_send_once(self):
        draft=self.draft();sent=[]
        send=lambda row: sent.append(row['payload']) or {'id':'receipt'}
        self.assertFalse(dispatch(self.map,send))
        edited=self.draft(id=str(draft['id']),expected_version=1,body='A corrected body.')
        with self.assertRaisesRegex(psycopg.Error,'draft_changed'): self.approve(draft)
        self.approve(edited);self.approve(edited)
        self.assertTrue(dispatch(self.map,send));self.assertFalse(dispatch(self.map,send))
        self.assertEqual(sent,[edited['payload']])
        self.assertEqual(self.approve(edited)['state'],'sent')
        with self.assertRaises(ToolError):self.draft(id=str(draft['id']),expected_version=2,body='Changed after approval.')

    def test_missing_approval_or_foreign_device_is_rejected(self):
        draft=self.draft()
        with self.assertRaisesRegex(psycopg.Error,'draft_not_approved'):
            self.map.execute("update assistant.email_drafts set state='queued' where id=%s",(draft['id'],))
        with self.assertRaisesRegex(psycopg.Error,'device_denied'):
            self.map.value('select public.assistant_email(%s,%s,%s,%s)',(self.owner,uuid.uuid4(),'approve',jsonb({'id':str(draft['id'])})))
        with self.assertRaisesRegex(psycopg.Error,'account_denied'):
            self.map.value('select public.assistant_email(%s,%s,%s,%s)',(uuid.uuid4(),self.device,'list',jsonb({})))
        names=[s.name for s in self.tools.read_specs()]
        self.assertIn('google_mail_draft',names)
        self.assertFalse(any('send' in name or 'approve' in name for name in names))

    def test_approved_payload_cannot_be_changed_and_errors_never_retry(self):
        draft=self.draft();self.approve(draft)
        with self.assertRaisesRegex(psycopg.Error,'draft_locked'):
            self.map.execute("update assistant.email_drafts set payload=jsonb_set(payload,'{body}',%s) where id=%s",(jsonb('injected'),draft['id']))
        calls=[]
        def uncertain(row):calls.append(row);raise TimeoutError()
        self.assertTrue(dispatch(self.map,uncertain));self.assertFalse(dispatch(self.map,uncertain))
        self.assertEqual(len(calls),1)
        self.assertEqual(self.approve(draft)['state'],'uncertain')

    def test_crashed_send_is_marked_uncertain_without_retry(self):
        draft=self.draft();self.approve(draft)
        self.map.execute("update assistant.email_drafts set state='sending',sending_at=now()-interval '3 minutes' where id=%s",(draft['id'],))
        self.assertFalse(dispatch(self.map,lambda _:self.fail('Must not retry')))
        self.assertEqual(self.run_async(self.drafts.read({'id':draft['id']}))['state'],'uncertain')

    def test_headers_cannot_inject_extra_recipients(self):
        for value in ['a@example.com\nBcc: other@example.com','a@example.com, b@example.com','not-an-address']:
            with self.assertRaises(ToolError):addresses([value])
        with self.assertRaises(ToolError):self.draft(subject='Subject\r\nBcc: other@example.com')
        with self.assertRaises(ToolError):self.draft(to=[])

    def test_delivery_preserves_visible_recipients_and_reply_headers(self):
        import base64
        from email import message_from_bytes
        from unittest.mock import MagicMock
        row=self.draft(cc=['copy@example.com'],bcc=['blind@example.com'])
        row['payload'].update(in_reply_to='<original@example.com>',references='<original@example.com>',thread_id='abc123')
        client=MagicMock();client.get.return_value.json.return_value={'emailAddress':'owner@example.com'}
        client.post.return_value.json.return_value={'id':'receipt','threadId':'abc123'}
        with patch('engine.integrations.email.session') as factory:
            factory.return_value.__enter__.return_value=client
            self.assertEqual(deliver(row)['id'],'receipt')
        body=client.post.call_args.kwargs['json'];email=message_from_bytes(base64.urlsafe_b64decode(body['raw']))
        self.assertEqual(email['To'],'recipient@example.com');self.assertEqual(email['Cc'],'copy@example.com');self.assertEqual(email['Bcc'],'blind@example.com')
        self.assertEqual(email['In-Reply-To'],'<original@example.com>');self.assertEqual(body['threadId'],'abc123')
        self.assertEqual(client.post.call_count,1)
