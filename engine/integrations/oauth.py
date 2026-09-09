"""Refresh account connections without sending credentials through model tools."""
import json
from datetime import datetime, timedelta, timezone

import requests
from engine import credentials
from engine.tools import ConnectionRequired, ToolError

from engine.integrations.catalog import OAUTH_PROVIDERS

ENDPOINTS = {key: item["oauth"]["token"] for key, item in OAUTH_PROVIDERS.items()}


def configured(provider):
    if provider not in OAUTH_PROVIDERS:
        return True
    import keyring
    import os
    if os.environ.get('ASSISTANT_CREDENTIAL_KEY'):
        return None  # Hosted registrations are owned and reported by the gateway.
    try:
        stored = keyring.get_password('com.carterwatts.personal-assistant.oauth-apps', provider)
        client = json.loads(stored) if stored else {}
        return bool(client.get('client_id') and (OAUTH_PROVIDERS[provider]['oauth']['clientAuth'] == 'pkce' or client.get('client_secret')))
    except (keyring.errors.KeyringError, ValueError, TypeError):
        return False


def access_token(provider, service, account, stored):
    if not stored.startswith('{'):
        return stored  # Previously connected personal tokens still work.
    try:
        value = json.loads(stored)
        token = value['token']
        expiry = value.get('expiry')
        if not expiry or datetime.fromisoformat(expiry.replace('Z', '+00:00')) > datetime.now(timezone.utc) + timedelta(seconds=60):
            return token
        if not value.get('refresh_token'):
            raise ValueError('No refresh token')
        endpoint = ENDPOINTS[provider]
        data = {'grant_type': 'refresh_token', 'refresh_token': value['refresh_token']}
        auth = None
        if OAUTH_PROVIDERS[provider]["oauth"]["clientAuth"] == "basic":
            auth = (value['client_id'], value['client_secret'])
        elif OAUTH_PROVIDERS[provider]['oauth']['clientAuth'] == 'pkce':
            data['client_id'] = value['client_id']
        else:
            data.update(client_id=value['client_id'], client_secret=value['client_secret'])
        response = requests.post(endpoint, data=data, auth=auth, headers={'Accept':'application/json'}, timeout=15, allow_redirects=False)
        if response.status_code >= 500 or response.status_code == 429:
            raise ToolError('The sign-in service is temporarily unavailable. Try again shortly.')
        if response.status_code != 200:
            raise ValueError('Refresh rejected')
        refreshed = response.json()
        if not refreshed.get('access_token') or refreshed.get('error'):
            raise ValueError('Refresh rejected')
        value['token'] = refreshed['access_token']
        value['refresh_token'] = refreshed.get('refresh_token', value['refresh_token'])
        value['expiry'] = (datetime.now(timezone.utc) + timedelta(seconds=refreshed.get('expires_in', 3600))).isoformat()
        credentials.set_password(service, account, json.dumps(value))
        return value['token']
    except requests.RequestException:
        raise ToolError('The sign-in service is temporarily unreachable.') from None
    except (ValueError, KeyError, TypeError):
        raise ConnectionRequired('Please sign in again to renew this connection.', f'{provider}_connect') from None


def connect_local(provider, service, account):
    import base64
    import hashlib
    from http.server import BaseHTTPRequestHandler, HTTPServer
    import keyring
    import secrets
    import time
    from urllib.parse import parse_qs, urlencode, urlsplit
    import webbrowser

    stored=keyring.get_password('com.carterwatts.personal-assistant.oauth-apps',provider)
    if not stored: raise ToolError('The developer sign-in registration is not configured on this Mac yet.')
    client=json.loads(stored)
    state=secrets.token_urlsafe(32);verifier=secrets.token_urlsafe(48)
    challenge=base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).decode().rstrip('=')
    callback=f'http://127.0.0.1:8766/{provider}/callback'
    received={}
    class Callback(BaseHTTPRequestHandler):
        def log_message(self,*args): pass  # Authorization codes never enter logs.
        def do_GET(self):
            url=urlsplit(self.path);args=parse_qs(url.query)
            if url.path!=f'/{provider}/callback' or not secrets.compare_digest(args.get('state',[''])[0],state):
                self.send_error(400);return
            received.update({k:v[0] for k,v in args.items()})
            self.send_response(200);self.send_header('Content-Type','text/plain');self.send_header('Cache-Control','no-store');self.end_headers()
            self.wfile.write(b'You can return to Bunny Man. The app will confirm the connection.')
    with HTTPServer(('127.0.0.1',8766),Callback) as server:
        server.timeout=1
        params={'client_id':client['client_id'],'redirect_uri':callback,'response_type':'code','state':state,'code_challenge':challenge,'code_challenge_method':'S256'}
        params.update(OAUTH_PROVIDERS[provider]["oauth"]["parameters"])
        authorize=OAUTH_PROVIDERS[provider]["oauth"]["authorize"]
        webbrowser.open(authorize+'?'+urlencode(params))
        deadline=time.monotonic()+300
        while not received and time.monotonic()<deadline:server.handle_request()
    if not received.get('code') or received.get('error'):raise ToolError('Sign-in was not completed.')
    data={'grant_type':'authorization_code','code':received['code'],'redirect_uri':callback,'code_verifier':verifier}
    auth=None
    if OAUTH_PROVIDERS[provider]["oauth"]["clientAuth"] == "basic":auth=(client['client_id'],client['client_secret'])
    elif OAUTH_PROVIDERS[provider]['oauth']['clientAuth'] == 'pkce':data['client_id']=client['client_id']
    else:data.update(client_id=client['client_id'],client_secret=client['client_secret'])
    response=requests.post(ENDPOINTS[provider],data=data,auth=auth,headers={'Accept':'application/json'},timeout=15,allow_redirects=False)
    if response.status_code!=200:raise ToolError('Sign-in was not completed.')
    token=response.json()
    if not token.get('access_token') or token.get('error'):raise ToolError('Sign-in was not completed.')
    if provider == 'spotify' and (not token.get('refresh_token') or not set(OAUTH_PROVIDERS[provider]['oauth']['parameters']['scope'].split()).issubset(token.get('scope','').split())):
        raise ToolError('Spotify did not grant the requested playback access.')
    value={**client,'token':token['access_token'],'refresh_token':token.get('refresh_token'),'provider':provider,
           'expiry':(datetime.now(timezone.utc)+timedelta(seconds=token['expires_in'])).isoformat() if token.get('expires_in') else None}
    from engine.integrations.accounts import _request, PROVIDERS
    _request(provider,PROVIDERS[provider][2],token=value['token'])
    credentials.set_password(service,account,json.dumps(value))
