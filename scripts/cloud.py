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


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='action', required=True)
    owner = commands.add_parser('bind-owner')
    owner.add_argument('email')
    commands.add_parser('configure')
    commands.add_parser('auth')
    args = parser.parse_args()
    try:
        if args.action == 'bind-owner':
            bind_owner(args.email)
        elif args.action == 'auth':
            configure_auth()
        else:
            configure()
    except Exception as error:
        print(str(error) if isinstance(error, RuntimeError) else f'Provisioning failed ({type(error).__name__}).')
        raise SystemExit(1) from None
