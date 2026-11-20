"""Configure the Mac client after the home database has been verified."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('host', help='SSH destination, for example user@home-server')
    args = parser.parse_args()
    if args.host.startswith('-') or any(c.isspace() for c in args.host):
        parser.error('Use an SSH host or user@host.')
    command = ('cd personal-assistant/deploy/home && '
               'docker compose -f compose.yaml -f api.compose.yaml -f worker.compose.yaml config --format json')
    result = subprocess.run(['ssh', '-o', 'BatchMode=yes', args.host, command], capture_output=True, check=True)
    config = json.loads(result.stdout)['services']['worker']['environment']
    url = config['ASSISTANT_DATABASE_URL'].replace('@db:5432/', '@127.0.0.1:55434/')
    if '@127.0.0.1:55434/' not in url:
        raise RuntimeError('Unexpected home database address.')
    root = Path.home() / '.config/personal-assistant'
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    path = root / 'settings.json'
    settings = json.loads(path.read_text()) if path.exists() else {}
    if path.exists():
        backup = root / 'settings.before-home.json'
        if not backup.exists():
            backup.write_bytes(path.read_bytes())
            backup.chmod(0o600)
    settings.update(ASSISTANT_DATABASE_URL=url,
                    ASSISTANT_SUPABASE_URL=config['ASSISTANT_PUBLIC_URL'],
                    ASSISTANT_PUBLIC_URL=config['ASSISTANT_PUBLIC_URL'],
                    ASSISTANT_STORAGE_KEY=config['ASSISTANT_STORAGE_KEY'])
    path.write_text(json.dumps(settings, indent=2) + '\n')
    path.chmod(0o600)
    label = 'com.carterwatts.personal-assistant.database-tunnel'
    agent = Path.home() / 'Library/LaunchAgents' / (label + '.plist')
    agent.parent.mkdir(parents=True, exist_ok=True)
    agent.write_bytes(plistlib.dumps(dict(Label=label, RunAtLoad=True, KeepAlive=True, ThrottleInterval=10,
        ProgramArguments=['/usr/bin/ssh', '-NT', '-o', 'BatchMode=yes', '-o', 'ExitOnForwardFailure=yes',
                          '-o', 'ServerAliveInterval=15', '-o', 'ServerAliveCountMax=3',
                          '-L', '127.0.0.1:55434:127.0.0.1:55433', args.host])))
    agent.chmod(0o600)
    domain = 'gui/' + str(os.getuid())
    subprocess.run(['launchctl', 'bootout', domain + '/' + label], capture_output=True)
    subprocess.run(['launchctl', 'bootstrap', domain, str(agent)], capture_output=True, check=True)
    print('Mac settings saved privately. The database tunnel reconnects automatically.')


if __name__ == '__main__':
    os.umask(0o077)
    main()
