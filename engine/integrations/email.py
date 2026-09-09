"""Draft tools and a deterministic sender. Approval is a separate client operation."""
import asyncio
import base64
import re
from email.message import EmailMessage
from email.policy import SMTP
from email.utils import getaddresses
from datetime import datetime, timezone
from engine.db import Map, jsonb
from engine.tools import ToolSpec, ToolError, ConnectionRequired, _obj, _s
from engine.integrations import google

SLOT = 'google_mail_send'
SEND_SCOPE = 'https://www.googleapis.com/auth/gmail.send'


def session():
    # Sending permission is separate from the read-only Google connection.
    credentials = google._credentials(SLOT)
    if not credentials or not credentials.has_scopes([SEND_SCOPE]):
        raise ConnectionRequired('Connect email sending to prepare a draft for your review.', SLOT)
    if not credentials.valid:
        try:
            credentials.refresh(google.Request())
            google.keyring.set_password(google.SERVICE, google._account(SLOT), credentials.to_json())
        except Exception:
            raise ConnectionRequired('Reconnect email sending.', SLOT) from None
    return google.AuthorizedSession(credentials)


def original(message_id):
    with session() as client:
        response=client.get('https://gmail.googleapis.com/gmail/v1/users/me/messages/'+message_id,params={'format':'metadata','metadataHeaders':['Message-ID','References','Subject']},timeout=10)
        response.raise_for_status()
        return response.json()


def mailbox():
    with session() as client:
        response=client.get('https://gmail.googleapis.com/gmail/v1/users/me/profile',timeout=10)
        response.raise_for_status()
        return response.json()['emailAddress']


def addresses(values):
    if not isinstance(values,list) or len(values)>30: raise ToolError('Use at most 30 recipients per field.')
    result=[]
    for value in values:
        if not isinstance(value,str) or any(c in value for c in '\r\n') or len(value)>320:
            raise ToolError('Invalid recipient.')
        parsed=getaddresses([value])
        if len(parsed)!=1 or not re.fullmatch(r'[^\s<>@,;]+@[^\s<>@,;]+\.[^\s<>@,;]+',parsed[0][1]):
            raise ToolError('Use a complete email address for each recipient.')
        result.append(value.strip())
    return result


def content(args,sender):
    result={'from':sender,'to':addresses(args.get('to',[])), 'cc':addresses(args.get('cc',[])),
            'bcc':addresses(args.get('bcc',[])), 'subject':args['subject'],'body':args['body']}
    if not result['to']+result['cc']+result['bcc']: raise ToolError('An email needs a recipient.')
    if any(c in result['subject'] for c in '\r\n') or len(result['subject'])>998: raise ToolError('Invalid subject.')
    if not isinstance(result['body'],str) or not result['body'].strip() or len(result['body'])>60000: raise ToolError('Use a nonempty body under 60,000 characters.')
    return result


class Drafts:
    def __init__(self,tools): self.tools=tools;self.map=tools.map

    async def prepare(self,args):
        sender=await asyncio.to_thread(mailbox)
        payload=content(args,sender)
        payload['delivery_host']=self.tools.device
        if args.get('reply_to_message_id'):
            source=await asyncio.to_thread(original,args['reply_to_message_id'])
            headers={h['name'].lower():h['value'] for h in source.get('payload',{}).get('headers',[])}
            mid=headers.get('message-id','')
            if not mid or '\r' in mid or '\n' in mid: raise ToolError('The original email has no usable Message-ID.')
            payload.update(thread_id=source['threadId'],in_reply_to=mid,references=(headers.get('references','')+' '+mid).strip())
            if any(c in payload['references'] for c in '\r\n'): raise ToolError('Invalid reply headers.')
            payload['subject']=headers.get('subject',payload['subject'])
            if any(c in payload['subject'] for c in '\r\n'): raise ToolError('Invalid original subject.')
        owner=self.map.value('select user_id from assistant.owner')
        if not owner: raise ToolError('Sign in to this installation before drafting email.')
        with self.map.conn.transaction():
            if args.get('id'):
                row=self.map.row("update assistant.email_drafts set payload=%s where id=%s and user_id=%s and state='draft' and version=%s returning *",
                                 (jsonb(payload),args['id'],owner,args.get('expected_version')))
                if not row: raise ToolError('The draft changed or is locked. Read it again before editing.')
            else:
                row=self.map.row('select * from assistant.email_drafts where user_id=%s and source_message=%s and payload=%s order by created_at desc limit 1',
                                 (owner,self.tools.message_id,jsonb(payload)))
                if not row: row=self.map.row('insert into assistant.email_drafts(user_id,source_message,payload) values(%s,%s,%s) returning *',
                                            (owner,self.tools.message_id,jsonb(payload)))
        return {'draft':row,'needs_review':row['state']=='draft','sent':row['state']=='sent'}

    async def read(self,args):
        row=self.map.row('select * from assistant.email_drafts where id=%s and user_id=(select user_id from assistant.owner)',(args['id'],))
        if not row: raise ToolError('Draft not found.')
        return row

    def specs(self):
        recipients={'type':'array','items':{'type':'string','maxLength':320},'maxItems':30}
        return [ToolSpec('google_mail_draft','Prepare or revise an email for the user’s draft popup. Never sends. Supply explicit recipients; read the original first for replies. The user must press Send on the exact draft; a spoken or typed yes cannot approve it. Editing requires id and expected_version.',
            _obj({'to':recipients,'cc':recipients,'bcc':recipients,'subject':_s('Subject',maxLength=998),'body':_s('Plain-text email',maxLength=60000),
                  'reply_to_message_id':_s('Original Gmail message ID',pattern='^[a-fA-F0-9]{1,64}$'),
                  'id':_s('Draft ID',format='uuid'),'expected_version':{'type':'integer','minimum':1}},['to','subject','body']),self.prepare),
                ToolSpec('google_mail_draft_read','Read a saved draft and its delivery status. Sent is confirmed only by the provider receipt.',_obj({'id':_s('Draft ID',format='uuid')},['id']),self.read)]


def deliver(row):
    payload=row['payload']
    with session() as client:
        response=client.get('https://gmail.googleapis.com/gmail/v1/users/me/profile',timeout=10)
        response.raise_for_status()
        if response.json()['emailAddress'].lower()!=payload['from'].lower(): raise ToolError('The sending account changed. Prepare a new draft.')
        email=EmailMessage(policy=SMTP)
        for key in ('from','to','cc','bcc','subject'):
            value=payload[key]
            if value: email[key]=', '.join(value) if isinstance(value,list) else value
        email['Message-ID']=f"<{row['id']}@personal-assistant.invalid>"
        if payload.get('in_reply_to'):
            email['In-Reply-To']=payload['in_reply_to']; email['References']=payload['references']
        email.set_content(payload['body'])
        body={'raw':base64.urlsafe_b64encode(email.as_bytes()).decode()}
        if payload.get('thread_id'): body['threadId']=payload['thread_id']
        # No retry: Gmail does not offer an idempotency key for send.
        response=client.post('https://gmail.googleapis.com/gmail/v1/users/me/messages/send',json=body,timeout=15)
        response.raise_for_status()
        result=response.json()
        if not result.get('id'): raise ToolError('No delivery receipt.')
        return {k:result[k] for k in ('id','threadId','labelIds') if k in result}


def dispatch(map_,send=deliver,delivery_host='cloud'):
    # A process dying after the HTTP request leaves an uncertain delivery, never a retry.
    map_.execute("update assistant.email_drafts set state='uncertain',error='Delivery was interrupted. Check Sent mail before drafting again.' where state='sending' and sending_at<now()-interval '2 minutes'")
    map_.execute("update assistant.email_drafts set state='failed',error='Approval expired before sending. Prepare a new draft.' where state='queued' and approved_at<now()-interval '5 minutes'")
    row=map_.row("update assistant.email_drafts set state='sending',sending_at=clock_timestamp() where id=(select id from assistant.email_drafts where state='queued' and approved_hash=content_hash and payload->>'delivery_host'=%s order by created_at for update skip locked limit 1) returning *",(delivery_host,))
    if not row: return False
    try:
        receipt=send(row)
        map_.execute("update assistant.email_drafts set state='sent',receipt=%s where id=%s and state='sending'",(jsonb(receipt),row['id']))
    except Exception:
        map_.execute("update assistant.email_drafts set state='uncertain',error='I could not confirm delivery. Check Gmail Sent before sending again.' where id=%s and state='sending'",(row['id'],))
    return True


async def run(url,host=None):
    # The sender has no model, tools, or conversational instructions.
    if host: await host.ready.wait()
    def tick():
        map_=Map(url)
        try: return dispatch(map_,delivery_host='cloud' if host else google.config.DEVICE)
        finally: map_.close()
    while not host or not host.stopping.is_set():
        try: await asyncio.to_thread(tick)
        except Exception: pass
        await asyncio.sleep(2)
