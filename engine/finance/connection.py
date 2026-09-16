"""Mac sign-in uses the same owned intents and hosted callback as the phone."""
import base64
import hashlib
import json
import os
import secrets
import time
import uuid
import webbrowser

from cryptography.hazmat.primitives.ciphers.aead import AESGCM

from engine import config
from engine.db import Map, jsonb
from engine.finance.plaid import Plaid, settings
from engine.tools import ToolError

SERVICE='com.carterwatts.personal-assistant.plaid'


def status():
    configured=False
    try: settings(); configured=True
    except Exception: pass
    map_=Map()
    try: connected=bool(map_.value('select exists(select 1 from assistant.bank_items where user_id=(select user_id from assistant.owner) and active)'))
    finally: map_.close()
    return {'label':'Bank accounts','connected':connected,'configured':configured,'kind':'bank_link',
            'capabilities':['balances.read','transactions.read','liabilities.read']}


def local_device(map_):
    import keyring
    owner=map_.value('select user_id from assistant.owner')
    if not owner: raise ToolError('Bank sign-in needs this installation’s owner account.')
    device=keyring.get_password(SERVICE,config.ENV+':device')
    if not device:
        device=str(uuid.uuid4()); keyring.set_password(SERVICE,config.ENV+':device',device)
        map_.value("select public.assistant_client(%s,%s,'register','{\"name\":\"Mac bank connections\"}')",(owner,device))
    return owner,device


def connect():
    import keyring
    api=Plaid()
    if config.ENV=='test': raise ToolError('Use the bank Sandbox integration tests; live bank sign-in is available in main chat.')
    key=keyring.get_password(SERVICE,'cipher-key')
    gateway=api.settings.get('gateway')
    if not key or not gateway: raise ToolError('Bank sign-in is not configured on this Mac yet.')
    map_=Map(); intent=None
    try:
        owner,device=local_device(map_)
        state=secrets.token_urlsafe(32); hashed=base64.urlsafe_b64encode(hashlib.sha256(state.encode()).digest()).decode().rstrip('=')
        repair=map_.value("select public.assistant_bank_store(%s,%s,'repair','{}')",(owner,device))
        if repair and repair['environment']!=api.environment:raise ToolError('Bank connection environment mismatch.')
        from engine.finance.sync import decrypt
        products={'access_token':decrypt(repair)} if repair else {'products':['transactions'],'optional_products':['liabilities']}
        linked=api.call('/link/token/create',client_name=config.ASSISTANT_NAME,user={'client_user_id':str(owner)},
                        redirect_uri='https://secure.plaid.com/oauth/redirect',language='en',country_codes=['US'],**products,
                        hosted_link={'is_mobile_app':False,'url_lifetime_seconds':600,'completion_redirect_uri':gateway+'/plaid/callback?state='+state})
        nonce=os.urandom(12)
        data=json.dumps({'link_token':linked['link_token'],'environment':api.environment,'repair':repair,'desktop':True}).encode()
        verifier=base64.b64encode(nonce+AESGCM(base64.b64decode(key)).encrypt(nonce,data,('oauth:'+hashed).encode())).decode()
        intent=map_.value("select public.assistant_connection_store(%s,%s,'begin',%s)",(owner,device,jsonb({'slot':'plaid','state_hash':hashed,'verifier':verifier})))
        webbrowser.open(linked['hosted_link_url'])
        for _ in range(300):
            result=map_.value("select public.assistant_connection_store(%s,%s,'status',%s)",(owner,device,jsonb(intent)))
            if result['state']=='connected': return status()
            if result['state']=='failed': raise ToolError('Bank sign-in was not completed. Please try again.')
            time.sleep(2)
        raise ToolError('Bank sign-in expired. Please try again.')
    finally: map_.close()


def disconnect():
    map_=Map()
    try:
        owner,device=local_device(map_)
        map_.value("select public.assistant_bank_store(%s,%s,'remove','{}')",(owner,device))
    finally: map_.close()
    return status()
