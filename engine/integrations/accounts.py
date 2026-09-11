"""Optional personal-account connections. Credentials never enter the conversation."""
import json
import threading

from engine import credentials as keyring
import requests

from engine import config
from engine.tools import ConnectionRequired, ToolError

from engine.integrations.catalog import ACCOUNT_PROVIDERS, OAUTH_PROVIDERS

PROVIDERS = {key: (item["name"], item["apiBase"], item["profile"])
             for key, item in ACCOUNT_PROVIDERS.items()}
CONNECTION_ACTIONS = {item["action"] for item in ACCOUNT_PROVIDERS.values()}
SERVICE = "com.carterwatts.personal-assistant.connections"
_LOCK = threading.RLock()


def _account(provider):
    if provider not in PROVIDERS:
        raise ToolError("Unknown connection.")
    return f"{config.ENV}:{provider}"


def status():
    result = {}
    for provider, (label, _, _) in PROVIDERS.items():
        try:
            connected = bool(keyring.get_password(SERVICE, _account(provider)))
            from engine.integrations.oauth import configured
            result[provider] = {"label": label, "connected": connected,
                                "configured": configured(provider), "kind": ACCOUNT_PROVIDERS[provider]["auth"],
                                "capabilities": ACCOUNT_PROVIDERS[provider]["capabilities"]}
        except Exception:
            result[provider] = {"label": label, "connected": False, "message": "Unlock your keychain to connect."}
    return result


def _request(provider, path, *, params=None, body=None, token=None, method=None):
    label, base, _ = PROVIDERS[provider]
    saved_access = token is None
    if token is None:
        with _LOCK, keyring.refresh_lock(SERVICE, _account(provider)):
            try:
                token = keyring.get_password(SERVICE, _account(provider))
                if token:
                    from engine.integrations.oauth import access_token
                    token = access_token(provider, SERVICE, _account(provider), token)
            except keyring.errors.KeyringError:
                raise ConnectionRequired(f"{label} credentials are unavailable on this host.", f"{provider}_connect") from None
    if not token:
        raise ConnectionRequired(f"Connect {label} using the connection button in the chat.", f"{provider}_connect")
    if path.startswith(("/", "http:", "https:")):
        raise ToolError("Invalid resource path.")
    headers = {"Authorization": "Bearer " + token, "User-Agent": "personal-assistant", "Accept": "application/json"}
    headers.update(ACCOUNT_PROVIDERS[provider]["headers"])
    # Provider modules choose endpoints; the separate owner-development tools gate writes.
    try:
        with requests.request(method or ("POST" if body is not None else "GET"), base + path,
                              headers=headers, params=params, json=body, timeout=10,
                              allow_redirects=False, stream=True) as response:
            if response.status_code == 401:
                if provider == 'notion' and saved_access:
                    from engine.integrations.oauth import access_token
                    renewed = None
                    with _LOCK, keyring.refresh_lock(SERVICE, _account(provider)):
                        stored = keyring.get_password(SERVICE, _account(provider))
                        if stored and stored.startswith('{') and json.loads(stored).get('refresh_token'):
                            renewed = access_token(provider, SERVICE, _account(provider), stored,
                                                   force=json.loads(stored).get('token') == token)
                    if renewed:
                        return _request(provider, path, params=params, body=body, token=renewed, method=method)
                raise ConnectionRequired(f"{label} rejected the credential. Reconnect in the chat.", f"{provider}_connect")
            if response.status_code == 403:
                if provider == 'spotify':
                    raise ToolError('Spotify denied playback. On-demand controls need Premium; also check the developer app allows this account.')
                raise ToolError(f"{label} denied access. Check the account's permissions or rate limit.")
            if response.status_code == 404:
                if provider == 'spotify' and path.startswith('me/player'):
                    raise ToolError('Spotify has no available player on that device. Open Spotify there first.')
                raise ToolError(f"This item is missing or not shared with the {label} connection.")
            if response.status_code == 429:
                raise ToolError(f"{label} is rate-limiting requests. Try again later.")
            if not 200 <= response.status_code < 300:
                raise ToolError(f"{label} could not complete the request. Try again later.")
            data = bytearray()
            for chunk in response.iter_content(8192):
                data.extend(chunk)
                if len(data) > 512000:
                    raise ToolError("Too much data. Narrow the search or read a smaller page.")
            return json.loads(data) if data else None
    except requests.RequestException:
        raise ToolError(f"{label} is temporarily unreachable.") from None


def connect(provider, token):
    account = _account(provider)
    if provider in OAUTH_PROVIDERS and token is None:
        from engine.integrations.oauth import connect_local
        connect_local(provider,SERVICE,account)
        return status()[provider]
    if not isinstance(token, str) or not 8 <= len(token.strip()) <= 4096 or any(c.isspace() for c in token.strip()):
        raise ToolError("Paste the access token into the secure field.")
    token = token.strip()
    with _LOCK:
        _request(provider, PROVIDERS[provider][2], token=token)
        keyring.set_password(SERVICE, account, token)
    return status()


def disconnect(provider):
    with _LOCK:
        try:
            keyring.delete_password(SERVICE, _account(provider))
        except keyring.errors.PasswordDeleteError:
            pass
    return status()
