"""OS Keychain locally; authenticated encryption for the hosted worker."""
import base64
import os
import threading
import keyring
from keyring import errors
from engine import config


_reads = threading.local()

def _slot(service, account):
    if account != config.ENV and not account.startswith(config.ENV + ':'):
        raise errors.KeyringError('Wrong credential environment')
    if service.endswith('.google'):
        return account.split(':', 1)[1] if ':' in account else 'google_connect'
    return account.split(':', 1)[1]


def _cipher():
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM
    return AESGCM(base64.b64decode(os.environ['ASSISTANT_CREDENTIAL_KEY']))


def get_password(service, account):
    if not os.environ.get('ASSISTANT_CREDENTIAL_KEY'):
        return keyring.get_password(service, account)
    if config.ENV != 'prod': raise errors.KeyringError('Cloud credentials require the production environment')
    from engine.db import Map
    map_ = Map()
    try:
        slot = _slot(service, account)
        row = map_.row('select user_id,ciphertext from assistant.credentials where user_id=(select user_id from assistant.owner) and slot=%s', (slot,))
        if not row: return None
        _reads.values = getattr(_reads, 'values', {})
        _reads.values[(service, account)] = row['ciphertext']
        raw = base64.b64decode(row['ciphertext'])
        return _cipher().decrypt(raw[:12], raw[12:], f"{row['user_id']}:{slot}".encode()).decode()
    finally:
        map_.close()


def set_password(service, account, value):
    if not os.environ.get('ASSISTANT_CREDENTIAL_KEY'):
        return keyring.set_password(service, account, value)
    if config.ENV != 'prod': raise errors.KeyringError('Cloud credentials require the production environment')
    from engine.db import Map
    map_ = Map()
    try:
        slot = _slot(service, account)
        owner = map_.value('select user_id from assistant.owner')
        nonce = os.urandom(12)
        encrypted = base64.b64encode(nonce + _cipher().encrypt(nonce, value.encode(), f'{owner}:{slot}'.encode())).decode()
        # A refresh may not overwrite a reconnection or resurrect disconnected access.
        expected = getattr(_reads, 'values', {}).pop((service, account), None)
        map_.execute('update assistant.credentials set ciphertext=%s,updated_at=now() where user_id=%s and slot=%s and ciphertext=%s', (encrypted, owner, slot, expected))
    finally:
        map_.close()


def delete_password(service, account):
    if not os.environ.get('ASSISTANT_CREDENTIAL_KEY'):
        return keyring.delete_password(service, account)
    if config.ENV != 'prod': raise errors.KeyringError('Cloud credentials require the production environment')
    from engine.db import Map
    map_ = Map()
    try:
        map_.execute('delete from assistant.credentials where user_id=(select user_id from assistant.owner) and slot=%s', (_slot(service, account),))
    finally:
        map_.close()
