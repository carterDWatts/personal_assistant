"""Add local API signing keys to .env without replacing existing credentials."""
import base64
import hashlib
import hmac
import json
import os
from pathlib import Path
import secrets
import tempfile
import time


def token(secret, role, now):
    def encode(value):
        return base64.urlsafe_b64encode(value).rstrip(b'=')
    head = encode(b'{"alg":"HS256","typ":"JWT"}')
    body = encode(json.dumps({'role': role, 'iss': 'supabase', 'iat': now,
                              'exp': now + 10 * 365 * 86400}).encode())
    data = head + b'.' + body
    return (data + b'.' + encode(hmac.new(secret.encode(), data, hashlib.sha256).digest())).decode()


if __name__ == '__main__':
    path = Path(__file__).with_name('.env')
    if path.is_symlink():
        raise SystemExit('Refusing a symlink for private configuration.')
    existing = path.read_text() if path.exists() else ''
    values = dict(line.split('=', 1) for line in existing.splitlines()
                  if '=' in line and not line.lstrip().startswith('#'))
    names = {name for name, value in values.items() if value.strip()}
    required = {'JWT_SECRET', 'ANON_KEY', 'SERVICE_ROLE_KEY'}
    if names & required:
        if not required <= names:
            raise SystemExit('Incomplete signing configuration; refusing to rotate keys.')
        print('Signing keys already exist; left unchanged.')
        raise SystemExit(0)
    secret = secrets.token_hex(32)
    now = int(time.time())
    new = {'JWT_SECRET': secret, 'ANON_KEY': token(secret, 'anon', now),
           'SERVICE_ROLE_KEY': token(secret, 'service_role', now)}
    if 'POSTGRES_PASSWORD' not in names:
        new['POSTGRES_PASSWORD'] = secrets.token_hex(32)
    preserved = [line for line in existing.splitlines() if line.split('=', 1)[0] not in new]
    fd, temporary = tempfile.mkstemp(dir=path.parent, prefix='.env-')
    try:
        with os.fdopen(fd, 'w') as output:
            output.write('\n'.join(preserved) + '\n' + ''.join(f'{key}={value}\n' for key, value in new.items()))
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, path)
    finally:
        Path(temporary).unlink(missing_ok=True)
    print('Private signing configuration saved. No existing keys changed.')
