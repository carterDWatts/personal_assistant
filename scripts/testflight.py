#!/usr/bin/env python3
"""Wait for Apple to make an uploaded build available to internal testers."""
import argparse
import json
import os
from pathlib import Path
import time

import jwt
import requests


def availability(build, detail):
    if build['processingState'] in ('FAILED', 'INVALID'):
        raise RuntimeError('Apple rejected the uploaded build.')
    return build['processingState'] == 'VALID' and detail.get('internalBuildState') == 'IN_BETA_TESTING'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('build')
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    key = Path(os.environ['ASC_KEY_PATH']).read_text()

    def get(path, **params):
        now = int(time.time())
        token = jwt.encode({'iss': os.environ['ASC_ISSUER_ID'], 'iat': now, 'exp': now + 300,
                            'aud': 'appstoreconnect-v1'}, key, algorithm='ES256',
                           headers={'kid': os.environ['ASC_KEY_ID']})
        response = requests.get('https://api.appstoreconnect.apple.com/v1/' + path,
                                headers={'Authorization': 'Bearer ' + token}, params=params, timeout=30)
        response.raise_for_status()
        return response.json()['data']

    deadline = time.monotonic() + 1800
    while time.monotonic() < deadline:
        builds = get('builds', **{'filter[app]': os.environ['ASC_APP_ID'], 'filter[version]': args.build})
        if builds:
            build = builds[0]
            detail = get('builds/' + build['id'] + '/buildBetaDetail')['attributes']
            if availability(build['attributes'], detail):
                version = get('builds/' + build['id'] + '/preReleaseVersion')['attributes']['version']
                args.output.write_text(json.dumps({'version': version, 'build': args.build,
                                                    'available': True, 'commit': os.environ.get('GITHUB_SHA')}))
                print('Build ' + args.build + ' is available in TestFlight.', flush=True)
                return
        print('Waiting for Apple processing and internal testing availability.', flush=True)
        time.sleep(30)
    raise SystemExit('Apple has not made this build available within 30 minutes. Release remains unverified.')


if __name__ == '__main__':
    main()
