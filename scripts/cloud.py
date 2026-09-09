"""Provision the personal deployment without putting credentials in shell arguments."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import urllib.request
from urllib.parse import parse_qsl, urlencode, urlsplit, urlunsplit

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))
PROJECT = 'koauvyfxewczcajnlrfp'
RAILWAY = str(ROOT / '.railway/node_modules/.bin/railway')


def command(args, **kwargs):
    result = subprocess.run(args, cwd=ROOT, capture_output=True, text=True, **kwargs)
    if result.returncode:
        # CLIs may include credentials in diagnostics. Keep them out of logs.
        raise RuntimeError(f'{Path(args[0]).name} failed (exit {result.returncode}).')
    return result.stdout


def database():
    from engine.desktop import load_settings
    load_settings()
    from engine.db import Map
    url = os.environ.get('ASSISTANT_DATABASE_URL')
    if not url or PROJECT not in urlsplit(url).username:
        raise RuntimeError('Set the production connection for the expected Supabase project.')
    return Map(url)


def bind_owner(email):
    keys = json.loads(command(['supabase', 'projects', 'api-keys', '--project-ref', PROJECT, '-o', 'json']))
    key = next(k['api_key'] for k in keys if k['name'] == 'service_role')
    def auth(path, data=None):
        request = urllib.request.Request(f'https://{PROJECT}.supabase.co/auth/v1/admin/{path}',
            data=json.dumps(data).encode() if data else None,
            headers={'apikey': key, 'Authorization': f'Bearer {key}', 'Content-Type': 'application/json'})
        with urllib.request.urlopen(request, timeout=20) as response:
            return json.load(response)
    map_ = database()
    try:
        existing = map_.value('select user_id from assistant.owner')
        users = auth('users')['users']
        matches = [u for u in users if u.get('email', '').lower() == email.lower()]
        if existing:
            if not matches or str(existing) != matches[0]['id']:
                raise RuntimeError('A different owner is already bound. No changes made.')
            print('Owner is already bound.')
            return
        # Email ownership is still verified through the normal sign-in flow.
        user = matches[0] if matches else auth('users', {'email': email, 'email_confirm': False})
        map_.execute('insert into assistant.owner(user_id) values(%s)', (user['id'],))
        print('Owner bound. Email verification remains part of sign-in.')
    finally:
        map_.close()


def configure():
    project = json.loads(command([RAILWAY, 'status', '--json']))
    if project['name'] != 'personal-assistant':
        raise RuntimeError('Link the personal-assistant Railway project first.')
    map_ = database()
    try:
        parts = urlsplit(map_.url)
        query = dict(parse_qsl(parts.query))
        query.update(sslmode='verify-full', sslrootcert='/etc/ssl/certs/ca-certificates.crt')
        url = urlunsplit(parts._replace(query=urlencode(query)))
    finally:
        map_.close()
    command([RAILWAY, 'variable', 'set', 'ASSISTANT_DATABASE_URL', '--stdin', '--skip-deploys',
             '--service', 'worker'], input=url)
    login = Path.home() / '.codex/auth.json'
    if login.is_file():
        data = json.loads(login.read_text())
        if data.get('OPENAI_API_KEY') or not data.get('tokens', {}).get('refresh_token'):
            raise RuntimeError('The local login is not a ChatGPT subscription.')
        command([RAILWAY, 'variable', 'set', 'ASSISTANT_CODEX_AUTH_JSON', '--stdin', '--skip-deploys',
                 '--service', 'worker'], input=json.dumps(data))
    if token := os.environ.get('CLAUDE_CODE_OAUTH_TOKEN'):
        command([RAILWAY, 'variable', 'set', 'CLAUDE_CODE_OAUTH_TOKEN', '--stdin', '--skip-deploys',
                 '--service', 'worker'], input=token)
    print('Worker credentials configured. No credentials were written to the repository.')


def configure_speech():
    keys = json.loads(command(['supabase', 'projects', 'api-keys', '--project-ref', PROJECT, '-o', 'json']))
    key = next(k['api_key'] for k in keys if k['name'] == 'service_role')
    url = f'https://{PROJECT}.supabase.co'
    headers = {'apikey': key, 'Authorization': f'Bearer {key}', 'Content-Type': 'application/json'}
    request = urllib.request.Request(url + '/storage/v1/bucket', headers=headers)
    with urllib.request.urlopen(request, timeout=20) as response:
        buckets = json.load(response)
    bucket = next((b for b in buckets if b['id'] == 'speech'), None)
    if bucket and bucket.get('public'):
        raise RuntimeError('Speech bucket must be private.')
    if not bucket:
        request = urllib.request.Request(url + '/storage/v1/bucket', headers=headers,
            data=json.dumps({'id': 'speech', 'name': 'speech', 'public': False,
                             'file_size_limit': 5000000, 'allowed_mime_types': ['audio/mp4']}).encode())
        with urllib.request.urlopen(request, timeout=20) as response: response.read()
    for name, value in [('ASSISTANT_STORAGE_KEY', key), ('ASSISTANT_SUPABASE_URL', url)]:
        command([RAILWAY, 'variable', 'set', name, '--stdin', '--skip-deploys', '--service', 'worker'], input=value)
    print('Private speech storage configured. Worker credentials stay on the host.')


def configure_images():
    """Private persistent image assets; the native bridge keeps its key in Keychain."""
    import keyring
    keys = json.loads(command(['supabase', 'projects', 'api-keys', '--project-ref', PROJECT, '-o', 'json']))
    key = next(k['api_key'] for k in keys if k['name'] == 'service_role')
    url = f'https://{PROJECT}.supabase.co'
    headers = {'apikey': key, 'Authorization': f'Bearer {key}', 'Content-Type': 'application/json'}
    with urllib.request.urlopen(urllib.request.Request(url+'/storage/v1/bucket',headers=headers),timeout=20) as response:
        bucket=next((b for b in json.load(response) if b['id']=='chat-images'),None)
    if bucket and bucket.get('public'): raise RuntimeError('The image bucket must be private.')
    definition={'id':'chat-images','name':'chat-images','public':False,'file_size_limit':4000000,
                'allowed_mime_types':['image/jpeg','image/png','image/webp']}
    request=urllib.request.Request(url+'/storage/v1/bucket'+('/chat-images' if bucket else ''),headers=headers,
        method='PUT' if bucket else 'POST',data=json.dumps(definition).encode())
    with urllib.request.urlopen(request,timeout=20) as response: response.read()
    keyring.set_password('com.carterwatts.personal-assistant.storage','prod',json.dumps({'url':url,'key':key}))
    for name,value in [('ASSISTANT_STORAGE_KEY',key),('ASSISTANT_SUPABASE_URL',url)]:
        command([RAILWAY,'variable','set',name,'--stdin','--skip-deploys','--service','worker'],input=value)
    print('Private image storage configured. The Mac credential is in Keychain; hosted credentials stay on the worker.')


def configure_auth():
    import keyring
    token = (os.environ.get('SUPABASE_ACCESS_TOKEN') or keyring.get_password('Supabase CLI', 'supabase')
             or keyring.get_password('Supabase CLI', 'access-token'))
    if not token:
        raise RuntimeError('Sign in to the Supabase CLI first.')
    url = f'https://api.supabase.com/v1/projects/{PROJECT}/config/auth'
    headers = {'Authorization': f'Bearer {token}', 'Content-Type': 'application/json', 'User-Agent': 'Supabase CLI'}
    with urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=20) as response:
        current = json.load(response)
    redirects = [value.strip() for value in current.get('uri_allow_list', '').split(',') if value.strip()]
    callback = 'personal-assistant://auth/callback'
    if callback not in redirects:
        redirects.append(callback)
    desired = {'disable_signup': True, 'uri_allow_list': ','.join(redirects)}
    request = urllib.request.Request(url, method='PATCH', headers=headers, data=json.dumps(desired).encode())
    with urllib.request.urlopen(request, timeout=20) as response:
        response.read()
    with urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=20) as response:
        actual = json.load(response)
    if any(actual.get(k) != v for k, v in desired.items()):
        raise RuntimeError('Auth configuration did not match after applying it.')
    print('Phone sign-in callback configured and verified. Public signup is disabled.')


def configure_connections(client_file):
    import base64
    import tempfile
    client = json.loads(Path(client_file).read_text())["web"]
    callback = f'https://{PROJECT}.supabase.co/functions/v1/assistant/google/callback'
    if callback not in client.get('redirect_uris', []):
        raise RuntimeError('The Google web client needs the hosted callback URL.')
    directory = Path.home() / '.config/personal-assistant'
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    keyfile = directory / 'credential-key'
    if not keyfile.exists():
        descriptor = os.open(keyfile, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, 'w') as output:
            output.write(base64.b64encode(os.urandom(32)).decode())
    key = keyfile.read_text().strip()
    if len(base64.b64decode(key, validate=True)) != 32:
        raise RuntimeError('The saved credential key is invalid.')
    from engine.integrations.catalog import PROVIDERS
    registration = PROVIDERS['google']['oauth']
    values = {'ASSISTANT_CREDENTIAL_KEY': key, registration['clientIdEnv']: client['client_id'],
              registration['clientSecretEnv']: client['client_secret']}
    with tempfile.NamedTemporaryFile(mode='w', suffix='.env') as env:
        for name, value in values.items():
            env.write(f'{name}={value}\n')
        env.flush()
        command(['supabase','secrets','set','--project-ref',PROJECT,'--env-file',env.name])
    command([RAILWAY,'variable','set','ASSISTANT_CREDENTIAL_KEY','--stdin','--skip-deploys',
             '--service','worker'],input=key)
    print('Cloud connection credentials configured. The encryption key is saved outside the repository.')


def configure_account(provider, client_file):
    """Install a developer OAuth registration; end users only see the sign-in sheet."""
    import tempfile
    import keyring
    client=json.loads(Path(client_file).read_text())
    client_id,secret=client['client_id'],client.get('client_secret','')
    from engine.integrations.catalog import OAUTH_PROVIDERS
    registration=OAUTH_PROVIDERS[provider]['oauth']
    values=(client_id,) if registration['clientAuth']=='pkce' else (client_id,secret)
    if not all(isinstance(v,str) and v and not any(c.isspace() for c in v) for v in values):
        raise RuntimeError('Invalid OAuth client configuration.')
    with tempfile.NamedTemporaryFile(mode='w',suffix='.env') as env:
        env.write(f"{registration['clientIdEnv']}={client_id}\n")
        if secret: env.write(f"{registration['clientSecretEnv']}={secret}\n")
        env.flush()
        command(['supabase','secrets','set','--project-ref',PROJECT,'--env-file',env.name])
    keyring.set_password('com.carterwatts.personal-assistant.oauth-apps',provider,json.dumps(client))
    print('OAuth registration installed in the gateway and local Keychain.')


def configure_development():
    """Bind this private deployment to the owner's existing developer accounts."""
    import base64
    import keyring
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM
    import requests
    github=command(['gh','auth','token']).strip()
    supabase=keyring.get_password('Supabase CLI','supabase') or keyring.get_password('Supabase CLI','access-token')
    if not supabase:raise RuntimeError('Sign in to the Supabase CLI first.')
    repo='carterDWatts/personal_assistant'
    for provider,token,url in [('github',github,'https://api.github.com/repos/'+repo),('supabase',supabase,'https://api.supabase.com/v1/projects/'+PROJECT)]:
        response=requests.get(url,headers={'Authorization':'Bearer '+token},timeout=20)
        if response.status_code!=200:raise RuntimeError(provider+' account verification failed.')
        if provider=='github' and not response.json().get('permissions',{}).get('admin'):
            raise RuntimeError('The GitHub account must administer the assistant repository.')
    key=base64.b64decode((Path.home()/'.config/personal-assistant/credential-key').read_text().strip(),validate=True)
    cipher=AESGCM(key);map_=database()
    try:
        owner=map_.value('select user_id from assistant.owner')
        if not owner:raise RuntimeError('Bind the installation owner first.')
        # Verify the existing encryption key before installing additional credentials.
        sample=map_.row('select slot,ciphertext from assistant.credentials where user_id=%s limit 1',(owner,))
        if sample:
            raw=base64.b64decode(sample['ciphertext']);cipher.decrypt(raw[:12],raw[12:],f"{owner}:{sample['slot']}".encode())
        with map_.conn.transaction():
            for slot,token in [('github',github),('supabase',supabase)]:
                nonce=os.urandom(12)
                encrypted=base64.b64encode(nonce+cipher.encrypt(nonce,token.encode(),f'{owner}:{slot}'.encode())).decode()
                map_.execute('insert into assistant.credentials(user_id,slot,ciphertext) values(%s,%s,%s) on conflict(user_id,slot) do update set ciphertext=excluded.ciphertext,updated_at=now()', (owner,slot,encrypted))
        for name,value in {'ASSISTANT_DEVELOPER_OWNER':str(owner),'ASSISTANT_DEVELOPER_REPO':repo,'ASSISTANT_DEVELOPER_PROJECT':PROJECT}.items():
            command([RAILWAY,'variable','set',name,'--stdin','--skip-deploys','--service','worker'],input=value)
        print('Owner account access verified and encrypted. Development is scoped to this owner, repository and project.')
    finally:map_.close()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='action', required=True)
    owner = commands.add_parser('bind-owner')
    owner.add_argument('email')
    commands.add_parser('configure')
    commands.add_parser('auth')
    commands.add_parser('speech')
    commands.add_parser('images')
    commands.add_parser('development')
    reviews=commands.add_parser('development-reviews')
    reviews.add_argument('--disable',action='store_true')
    connections = commands.add_parser('connections')
    connections.add_argument('client_file')
    account = commands.add_parser('account')
    from engine.integrations.catalog import OAUTH_PROVIDERS
    account.add_argument('provider',choices=list(OAUTH_PROVIDERS))
    account.add_argument('client_file')
    args = parser.parse_args()
    try:
        if args.action == 'development-reviews':
            command([RAILWAY,'variable','set','ASSISTANT_DEVELOPMENT_REVIEW','--stdin','--skip-deploys','--service','worker'],input='0' if args.disable else '1')
            print('Development review setting saved. It takes effect on the next deployment.')
        elif args.action == 'development':
            configure_development()
        elif args.action == 'bind-owner':
            bind_owner(args.email)
        elif args.action == 'account':
            configure_account(args.provider,args.client_file)
        elif args.action == 'connections':
            configure_connections(args.client_file)
        elif args.action == 'images':
            configure_images()
        elif args.action == 'speech':
            configure_speech()
        elif args.action == 'auth':
            configure_auth()
        else:
            configure()
    except Exception as error:
        print(str(error) if isinstance(error, RuntimeError) else f'Provisioning failed ({type(error).__name__}).')
        raise SystemExit(1) from None
