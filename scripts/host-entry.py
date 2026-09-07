"""Initialize the mounted home once, then drop privileges before running models."""
import json
import os
from pathlib import Path


def main():
    if any(os.environ.get(key) for key in ('OPENAI_API_KEY', 'ANTHROPIC_API_KEY', 'ANTHROPIC_AUTH_TOKEN',
                                         'CLAUDE_CODE_USE_BEDROCK', 'CLAUDE_CODE_USE_VERTEX')):
        raise RuntimeError('API billing credentials are not allowed.')
    home = Path('/data')
    home.mkdir(exist_ok=True)
    if os.getuid() == 0:
        os.chown(home, 10001, 10001)
        home.chmod(0o700)
        os.setgroups([])
        os.setgid(10001)
        os.setuid(10001)
    seed = os.environ.pop('ASSISTANT_CODEX_AUTH_JSON', None)
    if seed:
        login = json.loads(seed)
        if login.get('OPENAI_API_KEY') or not login.get('tokens', {}).get('refresh_token'):
            raise RuntimeError('A ChatGPT subscription login is required.')
        directory = home / '.codex'
        directory.mkdir(mode=0o700, exist_ok=True)
        path = directory / 'auth.json'
        # Keep refreshed credentials across deployments. Never restore an older token.
        if not path.exists():
            fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(fd, 'w') as file:
                json.dump(login, file)
    os.execvp('python', ['python', '-m', 'engine.host'])


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        print(f'Host initialization failed ({type(error).__name__}).', flush=True)
        raise SystemExit(1) from None
