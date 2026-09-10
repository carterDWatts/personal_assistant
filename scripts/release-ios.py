#!/usr/bin/env python3
"""Archive and upload the iPhone app to private TestFlight testing."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import subprocess

ROOT = Path(__file__).resolve().parent.parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--archive-only', action='store_true', help='Build without uploading.')
    parser.add_argument('--upload-existing', action='store_true', help='Retry uploading the existing archive.')
    parser.add_argument('--build-number', type=int, help='Explicit monotonically increasing CI build number.')
    args = parser.parse_args()
    if args.archive_only and args.upload_existing:
        parser.error('Choose archive-only or upload-existing, not both.')

    version = subprocess.check_output(['xcodebuild', '-version'], text=True).splitlines()[0]
    if int(version.split()[1].split('.')[0]) < 26:
        parser.error('Select Xcode 26 or newer, or set DEVELOPER_DIR to its Contents/Developer folder.')

    output = ROOT / 'build' / 'TestFlight'
    output.mkdir(parents=True, exist_ok=True)
    archive = output / 'Assistant.xcarchive'
    auth = []
    credentials = [os.environ.get(name) for name in ('ASC_KEY_PATH', 'ASC_KEY_ID', 'ASC_ISSUER_ID')]
    config = Path.home() / '.config/personal-assistant/apple/release.json'
    if not any(credentials) and config.is_file():
        try:
            saved = json.loads(config.read_text())
            credentials = [saved[name] for name in ('key_path', 'key_id', 'issuer_id')]
        except (OSError, ValueError, KeyError, TypeError):
            parser.error(f'Invalid release credentials in {config}.')
    if any(credentials):
        if not all(credentials):
            parser.error('Set ASC_KEY_PATH, ASC_KEY_ID and ASC_ISSUER_ID together.')
        key = Path(credentials[0]).expanduser().resolve()
        if not key.is_file() or key.is_relative_to(ROOT):
            parser.error('Keep the App Store Connect private key outside the repository.')
        auth = ['-authenticationKeyPath', str(key), '-authenticationKeyID', credentials[1],
                '-authenticationKeyIssuerID', credentials[2]]

    def xcode(arguments, log_name):
        log = output / log_name
        print(f'Running Xcode. Log: {log}', flush=True)
        with log.open('w') as stream:
            result = subprocess.run(['xcodebuild', *arguments, '-allowProvisioningUpdates', *auth],
                                    cwd=ROOT, stdout=stream, stderr=subprocess.STDOUT)
        if result.returncode:
            raise SystemExit(f'Xcode failed. Read {log}; upload completion is unconfirmed.')

    if not args.upload_existing:
        build = str(args.build_number) if args.build_number else subprocess.check_output(['git', 'rev-list', '--count', 'HEAD'], cwd=ROOT, text=True).strip()
        xcode(['-project', 'ios/Assistant.xcodeproj', '-scheme', 'Assistant', '-configuration', 'Release',
               '-destination', 'generic/platform=iOS', '-archivePath', str(archive),
               f'CURRENT_PROJECT_VERSION={build}', 'archive'], 'archive.log')
    info = archive / 'Products/Applications/Assistant.app/Info.plist'
    if not info.is_file():
        raise SystemExit('No archive found. Run without --upload-existing first.')
    version = plistlib.loads(info.read_bytes())
    print(f"Archived {version['CFBundleDisplayName']} {version['CFBundleShortVersionString']} ({version['CFBundleVersion']}).")
    if args.archive_only:
        return
    settings = plistlib.loads((archive / 'Info.plist').read_bytes())
    options = output / 'ExportOptions.plist'
    options.write_bytes(plistlib.dumps({
        'method': 'app-store-connect', 'destination': 'upload', 'signingStyle': 'automatic',
        'teamID': settings['ApplicationProperties']['Team'],
        'manageAppVersionAndBuildNumber': not bool(args.build_number), 'testFlightInternalTestingOnly': True, 'uploadSymbols': True,
    }))
    xcode(['-exportArchive', '-archivePath', str(archive), '-exportPath', str(output / 'export'),
           '-exportOptionsPlist', str(options)], 'upload.log')
    print('Upload completed. Apple must process the build before TestFlight can offer it.')


if __name__ == '__main__':
    main()
