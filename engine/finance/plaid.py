"""Small read-only Plaid adapter. No payment or transfer endpoints."""
import json
import os
from decimal import Decimal

import requests

from engine import config
from engine.tools import ToolError


class PlaidError(ToolError):
    def __init__(self, code):
        self.code = code
        super().__init__('Bank data could not be refreshed (' + code + ').')


def settings():
    env = os.environ.get('PLAID_ENV', 'sandbox')
    data = {'environment': env, 'client_id': os.environ.get('PLAID_CLIENT_ID'), 'secret': os.environ.get('PLAID_SECRET')}
    if not data['client_id']:
        import keyring
        saved = keyring.get_password('com.carterwatts.personal-assistant.plaid', config.ENV)
        if saved:
            data = json.loads(saved)
    if data.get('environment') not in ('sandbox', 'production') or not data.get('client_id') or not data.get('secret'):
        raise ToolError('Bank sign-in is not configured on this host yet.')
    if config.ENV == 'test' and data['environment'] != 'sandbox':
        raise ToolError('Test memory cannot access production bank accounts.')
    return data


class Plaid:
    def __init__(self, settings_=None):
        self.settings = settings_ or settings()
        self.environment = self.settings['environment']
        if self.environment not in ('sandbox', 'production'):
            raise ValueError('Invalid Plaid environment')

    def call(self, path, **args):
        allowed = {'/link/token/create','/accounts/get','/transactions/sync','/liabilities/get','/item/get','/item/remove'}
        if path not in allowed:
            raise ValueError('Unsupported bank operation')
        try:
            with requests.post('https://' + self.environment + '.plaid.com' + path,
                               json={**{key:self.settings[key] for key in ('client_id','secret')}, **args},
                               headers={'Plaid-Version':'2020-09-14'}, timeout=(5, 25), allow_redirects=False) as response:
                data = json.loads(response.text, parse_float=Decimal)
                if not response.ok:
                    code = data.get('error_code', 'UNAVAILABLE')
                    raise PlaidError(code if isinstance(code,str) and code.replace('_','').isalnum() else 'UNAVAILABLE')
                return data
        except (requests.RequestException, ValueError):
            raise PlaidError('UNAVAILABLE') from None
